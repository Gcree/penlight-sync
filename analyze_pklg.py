#!/usr/bin/env python3
"""Summarize Apple PacketLogger Bluetooth HCI/ACL/ATT captures offline."""

import argparse
import datetime
import json
import struct
import sys
import uuid
from collections import Counter
from dataclasses import dataclass
from typing import BinaryIO, Dict, Iterable, List, Optional, Tuple


PKLG_HEADER_LENGTH = 9  # seconds, microseconds, and packet type after the length word
MAX_RECORD_LENGTH = 1024 * 1024
PACKET_HCI_EVENT = 0x01
PACKET_SENT_ACL = 0x02
PACKET_RECV_ACL = 0x03
L2CAP_CID_ATT = 0x0004
UUID_BASE = "00000000-0000-1000-8000-00805f9b34fb"


class PklgError(ValueError):
    """Malformed PacketLogger or decoded HCI data."""


@dataclass(frozen=True)
class Record:
    index: int
    seconds: int
    microseconds: int
    packet_type: int
    payload: bytes


def _read_exact(stream: BinaryIO, length: int) -> bytes:
    parts = []
    remaining = length
    while remaining:
        part = stream.read(remaining)
        if not part:
            break
        parts.append(part)
        remaining -= len(part)
    return b"".join(parts)


def iter_records(stream: BinaryIO) -> Iterable[Record]:
    """Read length-prefixed PKLG records; the length excludes its own 4 bytes."""
    index = 0
    while True:
        length_word = _read_exact(stream, 4)
        if not length_word:
            return
        index += 1
        if len(length_word) != 4:
            raise PklgError("record %d: truncated 4-byte length field" % index)
        length = struct.unpack(">I", length_word)[0]
        if length < PKLG_HEADER_LENGTH:
            raise PklgError("record %d: length %d is smaller than the %d-byte header" % (index, length, PKLG_HEADER_LENGTH))
        if length > MAX_RECORD_LENGTH:
            raise PklgError("record %d: length %d exceeds the %d-byte safety cap" % (index, length, MAX_RECORD_LENGTH))
        body = _read_exact(stream, length)
        if len(body) != length:
            raise PklgError("record %d: truncated body (expected %d bytes, got %d)" % (index, length, len(body)))
        seconds, microseconds = struct.unpack(">II", body[:8])
        if microseconds >= 1000000:
            raise PklgError("record %d: invalid microseconds value %d" % (index, microseconds))
        yield Record(index, seconds, microseconds, body[8], body[9:])


def _timestamp(record: Record, utc_offset_minutes: Optional[int]) -> Dict[str, object]:
    # The integer fields can represent device-local wall time; never infer the device timezone.
    raw_wall = datetime.datetime.fromtimestamp(record.seconds, datetime.timezone.utc)
    raw_wall = raw_wall.replace(microsecond=record.microseconds)
    return {
        "timestamp_seconds": record.seconds,
        "timestamp_microseconds": record.microseconds,
        "timestamp_iso_raw_wall_time": raw_wall.replace(tzinfo=None).isoformat(timespec="microseconds"),
        "timestamp_iso_utc": (
            (raw_wall - datetime.timedelta(minutes=utc_offset_minutes)).isoformat(timespec="microseconds").replace("+00:00", "Z")
            if utc_offset_minutes is not None else None
        ),
    }


def _address(raw: bytes) -> str:
    return ":".join("%02X" % byte for byte in reversed(raw))


def _address_type(value: int) -> str:
    return {0: "public", 1: "random", 2: "public_identity", 3: "random_identity"}.get(value, "unknown")


def _uuid(raw: bytes) -> str:
    if len(raw) == 2:
        short = int.from_bytes(raw, "little")
        return UUID_BASE[:4] + "%04x" % short + UUID_BASE[8:]
    if len(raw) == 16:
        return str(uuid.UUID(bytes=raw[::-1]))
    raise ValueError("UUID must be 2 or 16 bytes")


def _uuid16(raw: bytes) -> Optional[str]:
    if len(raw) == 2:
        return "0x%04X" % int.from_bytes(raw, "little")
    return None


def _att_name(opcode: int) -> str:
    return {
        0x12: "write_request",
        0x52: "write_command",
        0xD2: "signed_write_command",
        0x16: "prepare_write_request",
    }.get(opcode, "opcode_0x%02X" % opcode)


def _ad_local_name(ad_data: bytes) -> Optional[str]:
    offset = 0
    while offset < len(ad_data):
        field_length = ad_data[offset]
        if field_length == 0:
            break
        end = offset + 1 + field_length
        if end > len(ad_data):
            break
        ad_type = ad_data[offset + 1]
        if ad_type in (0x08, 0x09):
            name = ad_data[offset + 2:end].decode("utf-8", errors="replace").strip("\x00")
            return name or None
        offset = end
    return None


class Analyzer:
    def __init__(self, input_name: str = "<stream>", utc_offset_minutes: Optional[int] = None) -> None:
        if utc_offset_minutes is not None and not -840 <= utc_offset_minutes <= 840:
            raise ValueError("device UTC offset must be between -840 and 840 minutes")
        self.input_name = input_name
        self.utc_offset_minutes = utc_offset_minutes
        self.record_types = Counter()
        self.hci_events = 0
        self.acl_packets = 0
        self.l2cap_att_pdus = 0
        self.att_pdus = 0
        self.orphan_continuations = 0
        self.incomplete_assemblies = 0
        self.connections: List[Dict[str, object]] = []
        self.active: Dict[int, Dict[str, object]] = {}
        self.connection_by_id: Dict[str, Dict[str, object]] = {}
        self.fragments: Dict[Tuple[str, int, str], bytearray] = {}
        self.next_connection_id = 1
        self.local_names: Dict[str, Dict[str, object]] = {}
        self.pending_read_by_type: Dict[Tuple[str, str], str] = {}

    def consume(self, records: Iterable[Record]) -> Dict[str, object]:
        for record in records:
            self.record_types[record.packet_type] += 1
            if record.packet_type == PACKET_HCI_EVENT:
                self._hci_event(record)
            elif record.packet_type in (PACKET_SENT_ACL, PACKET_RECV_ACL):
                self._acl(record)

        self.incomplete_assemblies += len(self.fragments)
        write_count = sum(len(connection["writes"]) for connection in self.connections)
        prepare_write_count = sum(len(connection["prepare_writes"]) for connection in self.connections)
        service_count = sum(len(connection["services"]) for connection in self.connections)
        characteristic_count = sum(len(connection["characteristics"]) for connection in self.connections)
        return {
            "format": "Apple PacketLogger HCI/ACL/ATT summary",
            "input_file": self.input_name,
            "timestamp_note": (
                "Raw seconds/microseconds are retained and timestamp_iso_raw_wall_time renders them without a timezone. "
                "timestamp_iso_utc is null unless --device-utc-offset-minutes is supplied; with an explicit offset, "
                "that offset is subtracted from the raw device wall time. No machine or device timezone is inferred."
            ),
            "summary": {
                "records": sum(self.record_types.values()),
                "record_type_counts": {"0x%02X" % key: value for key, value in sorted(self.record_types.items())},
                "hci_events": self.hci_events,
                "acl_packets": self.acl_packets,
                "l2cap_att_pdus": self.l2cap_att_pdus,
                "att_pdus": self.att_pdus,
                "writes": write_count,
                "prepare_writes": prepare_write_count,
                "services": service_count,
                "characteristics": characteristic_count,
                "orphan_acl_continuations": self.orphan_continuations,
                "incomplete_acl_assemblies": self.incomplete_assemblies,
            },
            "advertising_names": sorted(self.local_names.values(), key=lambda item: (item["address"], item["name"])),
            "connections": self.connections,
        }

    def _new_connection(self, handle: int, record: Record) -> Dict[str, object]:
        connection_id = "c%d" % self.next_connection_id
        self.next_connection_id += 1
        connection = {
            "connection_id": connection_id,
            "handle": handle,
            "handle_hex": "0x%04X" % handle,
            "peer_address": None,
            "peer_address_type": None,
            "peer_address_type_code": None,
            "advertised_name": None,
            "device_name": None,
            "device_name_handle": None,
            "connection_event_seen": False,
            "connected_at": None,
            "disconnected_at": None,
            "services": [],
            "characteristics": [],
            "writes": [],
            "prepare_writes": [],
        }
        self.connections.append(connection)
        self.connection_by_id[connection_id] = connection
        self.active[handle] = connection
        return connection

    def _connection(self, handle: int, record: Record) -> Dict[str, object]:
        if handle not in self.active:
            return self._new_connection(handle, record)
        return self.active[handle]

    def _connection_complete(self, handle: int, address_type: int, address: bytes, record: Record) -> None:
        connection = self._connection(handle, record)
        connection["connection_event_seen"] = True
        connection["peer_address"] = _address(address)
        connection["peer_address_type"] = _address_type(address_type)
        connection["peer_address_type_code"] = address_type
        connection["connected_at"] = _timestamp(record, self.utc_offset_minutes)
        name = self.local_names.get(connection["peer_address"])
        if name:
            connection["advertised_name"] = name["name"]

    def _advertising_report(self, parameters: bytes, record: Record) -> None:
        if len(parameters) < 2:
            raise PklgError("record %d: truncated LE Advertising Report" % record.index)
        report_count = parameters[1]
        offset = 2
        for _ in range(report_count):
            if len(parameters) - offset < 9:
                raise PklgError("record %d: truncated advertising report header" % record.index)
            address_type = parameters[offset + 1]
            address = _address(parameters[offset + 2:offset + 8])
            data_length = parameters[offset + 8]
            end = offset + 9 + data_length
            if len(parameters) < end + 1:
                raise PklgError("record %d: truncated advertising report data" % record.index)
            name = _ad_local_name(parameters[offset + 9:end])
            if name:
                previous = self.local_names.get(address)
                if previous:
                    previous["name"] = name
                    previous["last_seen"] = _timestamp(record, self.utc_offset_minutes)
                    previous["address_type"] = _address_type(address_type)
                else:
                    self.local_names[address] = {
                        "address": address,
                        "address_type": _address_type(address_type),
                        "name": name,
                        "first_seen": _timestamp(record, self.utc_offset_minutes),
                        "last_seen": _timestamp(record, self.utc_offset_minutes),
                    }
                for connection in self.connections:
                    if connection["peer_address"] == address:
                        connection["advertised_name"] = name
            offset = end + 1  # RSSI follows the advertising data.
        if offset != len(parameters):
            raise PklgError("record %d: unexpected trailing bytes in advertising report" % record.index)

    def _hci_event(self, record: Record) -> None:
        payload = record.payload
        if len(payload) < 2:
            raise PklgError("record %d: truncated HCI event header" % record.index)
        event_code, parameter_length = payload[0], payload[1]
        if len(payload) != parameter_length + 2:
            raise PklgError("record %d: HCI event length says %d parameter bytes, got %d" % (
                record.index, parameter_length, len(payload) - 2))
        self.hci_events += 1
        parameters = payload[2:]
        if event_code == 0x3E and parameters:
            subevent = parameters[0]
            if subevent == 0x01:  # LE Connection Complete
                if len(parameters) < 19:
                    raise PklgError("record %d: truncated LE Connection Complete" % record.index)
                if parameters[1] == 0:
                    handle = int.from_bytes(parameters[2:4], "little")
                    self._connection_complete(handle, parameters[5], parameters[6:12], record)
            elif subevent == 0x0A:  # LE Enhanced Connection Complete
                if len(parameters) < 31:
                    raise PklgError("record %d: truncated LE Enhanced Connection Complete" % record.index)
                if parameters[1] == 0:
                    handle = int.from_bytes(parameters[2:4], "little")
                    self._connection_complete(handle, parameters[5], parameters[6:12], record)
            elif subevent == 0x02:
                self._advertising_report(parameters, record)
        elif event_code == 0x05:  # Disconnection Complete
            if len(parameters) != 4:
                raise PklgError("record %d: malformed Disconnection Complete" % record.index)
            if parameters[0] == 0:
                handle = int.from_bytes(parameters[1:3], "little")
                connection = self.active.pop(handle, None)
                if connection:
                    connection["disconnected_at"] = _timestamp(record, self.utc_offset_minutes)
                    connection_id = connection["connection_id"]
                    stale = [key for key in self.fragments if key[0] == connection_id]
                    self.incomplete_assemblies += len(stale)
                    for key in stale:
                        del self.fragments[key]

    def _acl(self, record: Record) -> None:
        payload = record.payload
        if len(payload) < 4:
            raise PklgError("record %d: truncated HCI ACL header" % record.index)
        flags, data_length = struct.unpack("<HH", payload[:4])
        if len(payload) != data_length + 4:
            raise PklgError("record %d: HCI ACL length says %d data bytes, got %d" % (
                record.index, data_length, len(payload) - 4))
        self.acl_packets += 1
        handle = flags & 0x0FFF
        packet_boundary = (flags >> 12) & 0x03
        direction = "outgoing" if record.packet_type == PACKET_SENT_ACL else "incoming"
        connection = self._connection(handle, record)
        connection_id = connection["connection_id"]
        key = (connection_id, handle, direction)
        fragment = payload[4:]

        if packet_boundary == 0x01:  # Continuation fragment.
            if key not in self.fragments:
                self.orphan_continuations += 1
                return
            self.fragments[key].extend(fragment)
            self._finish_l2cap_if_ready(key, connection, direction, record)
            return

        if key in self.fragments:
            self.incomplete_assemblies += 1
            del self.fragments[key]
        if packet_boundary == 0x03:
            raise PklgError("record %d: reserved HCI ACL packet-boundary flag 0b11" % record.index)
        self.fragments[key] = bytearray(fragment)
        self._finish_l2cap_if_ready(key, connection, direction, record)

    def _finish_l2cap_if_ready(self, key: Tuple[str, int, str], connection: Dict[str, object], direction: str, record: Record) -> None:
        fragment = self.fragments[key]
        if len(fragment) < 4:
            return
        expected = 4 + int.from_bytes(fragment[:2], "little")
        if len(fragment) > expected:
            raise PklgError("record %d: ACL fragments exceed declared L2CAP PDU length" % record.index)
        if len(fragment) == expected:
            del self.fragments[key]
            self._parse_l2cap(connection, direction, bytes(fragment), record)

    def _parse_l2cap(self, connection: Dict[str, object], direction: str, l2cap: bytes, record: Record) -> None:
        if len(l2cap) < 4:
            raise PklgError("record %d: complete ACL packet lacks an L2CAP header" % record.index)
        payload_length, cid = struct.unpack("<HH", l2cap[:4])
        if len(l2cap) != payload_length + 4:
            raise PklgError("record %d: complete L2CAP PDU length mismatch" % record.index)
        if cid != L2CAP_CID_ATT:
            return
        self.l2cap_att_pdus += 1
        att = l2cap[4:]
        if not att:
            raise PklgError("record %d: empty ATT PDU" % record.index)
        self._att(connection, direction, att, record)

    def _characteristic_for_handle(self, connection: Dict[str, object], handle: int) -> Optional[Dict[str, object]]:
        for characteristic in connection["characteristics"]:
            if characteristic["value_handle"] == handle:
                return characteristic
        return None

    def _add_write(self, connection: Dict[str, object], record: Record, direction: str, opcode: int,
                   handle: int, value: bytes, offset: Optional[int] = None) -> None:
        characteristic = self._characteristic_for_handle(connection, handle)
        write = {
            "connection_id": connection["connection_id"],
            "handle": handle,
            "handle_hex": "0x%04X" % handle,
            "characteristic_uuid": characteristic["uuid"] if characteristic else None,
            "operation": _att_name(opcode),
            "opcode": "0x%02X" % opcode,
            "direction": direction,
            "value_length": len(value),
            "value_hex": value.hex(),
        }
        if characteristic and characteristic.get("uuid_16"):
            write["characteristic_uuid_16"] = characteristic["uuid_16"]
        if offset is not None:
            write["offset"] = offset
        write.update(_timestamp(record, self.utc_offset_minutes))
        # A Prepare Write only stages bytes. It does not prove the client later
        # sent Execute Write, or that the server accepted the assembled value.
        collection = "prepare_writes" if opcode == 0x16 else "writes"
        connection[collection].append(write)

    def _att(self, connection: Dict[str, object], direction: str, pdu: bytes, record: Record) -> None:
        self.att_pdus += 1
        opcode = pdu[0]
        connection_id = connection["connection_id"]
        if opcode in (0x12, 0x52, 0xD2):
            minimum = 15 if opcode == 0xD2 else 3
            if len(pdu) < minimum:
                raise PklgError("record %d: truncated ATT %s" % (record.index, _att_name(opcode)))
            handle = int.from_bytes(pdu[1:3], "little")
            value = pdu[3:-12] if opcode == 0xD2 else pdu[3:]
            self._add_write(connection, record, direction, opcode, handle, value)
        elif opcode == 0x16:
            if len(pdu) < 5:
                raise PklgError("record %d: truncated ATT Prepare Write Request" % record.index)
            handle = int.from_bytes(pdu[1:3], "little")
            offset = int.from_bytes(pdu[3:5], "little")
            self._add_write(connection, record, direction, opcode, handle, pdu[5:], offset)
        elif opcode == 0x08:  # Read By Type Request; remember characteristic declaration discovery.
            if len(pdu) not in (7, 21):
                raise PklgError("record %d: malformed ATT Read By Type Request" % record.index)
            request_uuid = _uuid(pdu[5:])
            key = (connection_id, direction)
            if request_uuid in ("00002803-0000-1000-8000-00805f9b34fb", "00002a00-0000-1000-8000-00805f9b34fb"):
                self.pending_read_by_type[key] = request_uuid
            else:
                self.pending_read_by_type.pop(key, None)
        elif opcode == 0x09:  # Read By Type Response.
            if len(pdu) < 2:
                raise PklgError("record %d: truncated ATT Read By Type Response" % record.index)
            request_direction = "outgoing" if direction == "incoming" else "incoming"
            key = (connection_id, request_direction)
            requested_uuid = self.pending_read_by_type.pop(key, None)
            if requested_uuid == "00002803-0000-1000-8000-00805f9b34fb":
                self._characteristics_response(connection, pdu, record)
            elif requested_uuid == "00002a00-0000-1000-8000-00805f9b34fb":
                self._device_name_response(connection, pdu, record)
        elif opcode == 0x11:  # Read By Group Type Response: service ranges and UUIDs.
            self._services_response(connection, pdu, record)

    def _characteristics_response(self, connection: Dict[str, object], pdu: bytes, record: Record) -> None:
        entry_length = pdu[1]
        if entry_length not in (7, 21) or (len(pdu) - 2) % entry_length:
            raise PklgError("record %d: malformed characteristic discovery response" % record.index)
        offset = 2
        while offset < len(pdu):
            declaration_handle = int.from_bytes(pdu[offset:offset + 2], "little")
            properties = pdu[offset + 2]
            value_handle = int.from_bytes(pdu[offset + 3:offset + 5], "little")
            uuid_bytes = pdu[offset + 5:offset + entry_length]
            characteristic = {
                "declaration_handle": declaration_handle,
                "value_handle": value_handle,
                "properties": properties,
                "uuid": _uuid(uuid_bytes),
                "uuid_16": _uuid16(uuid_bytes),
            }
            existing = next((item for item in connection["characteristics"] if item["value_handle"] == value_handle), None)
            if existing:
                existing.update(characteristic)
            else:
                connection["characteristics"].append(characteristic)
            offset += entry_length

    def _services_response(self, connection: Dict[str, object], pdu: bytes, record: Record) -> None:
        if len(pdu) < 2:
            raise PklgError("record %d: truncated ATT Read By Group Type Response" % record.index)
        entry_length = pdu[1]
        if entry_length not in (6, 20) or (len(pdu) - 2) % entry_length:
            raise PklgError("record %d: malformed service discovery response" % record.index)
        offset = 2
        while offset < len(pdu):
            start_handle = int.from_bytes(pdu[offset:offset + 2], "little")
            end_handle = int.from_bytes(pdu[offset + 2:offset + 4], "little")
            uuid_bytes = pdu[offset + 4:offset + entry_length]
            service = {
                "start_handle": start_handle,
                "end_handle": end_handle,
                "uuid": _uuid(uuid_bytes),
                "uuid_16": _uuid16(uuid_bytes),
            }
            if service not in connection["services"]:
                connection["services"].append(service)
            offset += entry_length

    def _device_name_response(self, connection: Dict[str, object], pdu: bytes, record: Record) -> None:
        if len(pdu) < 4:
            raise PklgError("record %d: truncated Device Name response" % record.index)
        entry_length = pdu[1]
        if entry_length < 2 or len(pdu) != entry_length + 2:
            raise PklgError("record %d: malformed Device Name response" % record.index)
        value_handle = int.from_bytes(pdu[2:4], "little")
        value = pdu[4:].decode("utf-8", errors="replace").strip("\x00")
        connection["device_name"] = value or None
        connection["device_name_handle"] = value_handle
        connection["device_name_seen_at"] = _timestamp(record, self.utc_offset_minutes)


def analyze_stream(stream: BinaryIO, input_name: str = "<stream>",
                   utc_offset_minutes: Optional[int] = None) -> Dict[str, object]:
    return Analyzer(input_name, utc_offset_minutes).consume(iter_records(stream))


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", help="local Apple PacketLogger .pklg file")
    parser.add_argument("-o", "--output", help="write JSON to this local path (default: stdout)")
    parser.add_argument(
        "--device-utc-offset-minutes", type=int,
        help="explicit UTC offset for the device's raw wall clock at capture time (for example, 480 for UTC+08:00)",
    )
    args = parser.parse_args(argv)
    try:
        with open(args.input, "rb") as source:
            result = analyze_stream(source, args.input, args.device_utc_offset_minutes)
        if args.output:
            with open(args.output, "w", encoding="utf-8") as destination:
                json.dump(result, destination, ensure_ascii=False, indent=2)
                destination.write("\n")
        else:
            json.dump(result, sys.stdout, ensure_ascii=False, indent=2)
            sys.stdout.write("\n")
        return 0
    except (OSError, PklgError, OverflowError, ValueError) as error:
        print("analyze_pklg.py: %s" % error, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
