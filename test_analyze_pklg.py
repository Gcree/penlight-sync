import io
import struct
import unittest

from analyze_pklg import PklgError, analyze_stream, iter_records


def record(packet_type, payload, seconds=1700000000, microseconds=123456):
    body = struct.pack(">II", seconds, microseconds) + bytes([packet_type]) + payload
    return struct.pack(">I", len(body)) + body


def event(event_code, parameters):
    return bytes([event_code, len(parameters)]) + parameters


def connection_complete(handle, address_wire, address_type=1):
    parameters = (
        bytes([0x01, 0x00]) + struct.pack("<H", handle) + bytes([0x00, address_type]) + address_wire
        + struct.pack("<HHHB", 24, 0, 300, 0)
    )
    return event(0x3E, parameters)


def disconnect(handle):
    return event(0x05, bytes([0x00]) + struct.pack("<H", handle) + bytes([0x13]))


def l2cap(att):
    return struct.pack("<HH", len(att), 0x0004) + att


def acl(handle, direction, boundary, data):
    packet_type = 0x02 if direction == "outgoing" else 0x03
    flags = handle | (boundary << 12)
    return record(packet_type, struct.pack("<HH", flags, len(data)) + data)


class AnalyzePklgTests(unittest.TestCase):
    def test_interleaved_connections_and_acl_fragments_stay_separate(self):
        addr_a = bytes.fromhex("060504030201")
        addr_b = bytes.fromhex("0c0b0a090807")
        write_a = bytes([0x52]) + struct.pack("<H", 0x000B) + b"\x07\xFF"
        write_b = bytes([0x12]) + struct.pack("<H", 0x0011) + b"\xAA"
        pdu_a = l2cap(write_a)
        data = b"".join([
            record(0x01, connection_complete(0x0040, addr_a)),
            record(0x01, connection_complete(0x0041, addr_b)),
            acl(0x0040, "outgoing", 0x02, pdu_a[:5]),
            acl(0x0041, "outgoing", 0x02, l2cap(write_b)),
            acl(0x0040, "outgoing", 0x01, pdu_a[5:]),
        ])

        result = analyze_stream(io.BytesIO(data))
        first, second = result["connections"]
        self.assertEqual(first["peer_address"], "01:02:03:04:05:06")
        self.assertEqual(second["peer_address"], "07:08:09:0A:0B:0C")
        self.assertEqual([(w["operation"], w["handle"], w["value_hex"]) for w in first["writes"]],
                         [("write_command", 0x000B, "07ff")])
        self.assertEqual([(w["operation"], w["handle"], w["value_hex"]) for w in second["writes"]],
                         [("write_request", 0x0011, "aa")])
        self.assertEqual(result["summary"]["incomplete_acl_assemblies"], 0)

    def test_handle_reuse_gets_a_new_connection_identity(self):
        data = b"".join([
            record(0x01, connection_complete(0x0040, bytes.fromhex("060504030201"))),
            record(0x01, disconnect(0x0040)),
            record(0x01, connection_complete(0x0040, bytes.fromhex("0c0b0a090807"))),
            acl(0x0040, "outgoing", 0x02, l2cap(bytes([0x52, 0x01, 0x00, 0x01]))),
        ])
        result = analyze_stream(io.BytesIO(data))
        self.assertEqual([c["connection_id"] for c in result["connections"]], ["c1", "c2"])
        self.assertEqual([c["peer_address"] for c in result["connections"]],
                         ["01:02:03:04:05:06", "07:08:09:0A:0B:0C"])
        self.assertEqual(result["connections"][0]["disconnected_at"]["timestamp_iso_utc"], None)
        self.assertEqual(result["connections"][1]["writes"][0]["connection_id"], "c2")

    def test_discovery_uuid_mapping_services_and_write_variants(self):
        handle = 0x0040
        custom_uuid = "00112233-4455-6677-8899-aabbccddeeff"
        custom_wire = bytes.fromhex("ffeeddccbbaa99887766554433221100")
        request16 = bytes([0x08, 0x01, 0x00, 0xff, 0xff, 0x03, 0x28])
        response16 = bytes([0x09, 0x07, 0x0a, 0x00, 0x02, 0x0b, 0x00, 0xf4, 0x00])
        request128 = bytes([0x08, 0x01, 0x00, 0xff, 0xff, 0x03, 0x28])
        response128 = bytes([0x09, 0x15, 0x0c, 0x00, 0x10, 0x0d, 0x00]) + custom_wire
        service_response = bytes([0x11, 0x06, 0x01, 0x00, 0x09, 0x00, 0x0f, 0x18])
        signed_signature = bytes(range(12))
        data = b"".join([
            record(0x01, connection_complete(handle, bytes.fromhex("060504030201"))),
            acl(handle, "outgoing", 0x02, l2cap(request16)),
            acl(handle, "incoming", 0x02, l2cap(response16)),
            acl(handle, "outgoing", 0x02, l2cap(request128)),
            acl(handle, "incoming", 0x02, l2cap(response128)),
            acl(handle, "incoming", 0x02, l2cap(service_response)),
            acl(handle, "outgoing", 0x02, l2cap(bytes([0x12, 0x0b, 0x00]) + b"on")),
            acl(handle, "outgoing", 0x02, l2cap(bytes([0xd2, 0x0d, 0x00]) + b"blue" + signed_signature)),
            acl(handle, "outgoing", 0x02, l2cap(bytes([0x16, 0x0d, 0x00, 0x02, 0x00]) + b"green")),
        ])

        result = analyze_stream(io.BytesIO(data))
        connection = result["connections"][0]
        chars = {item["value_handle"]: item for item in connection["characteristics"]}
        self.assertEqual(chars[0x000B]["uuid_16"], "0x00F4")
        self.assertEqual(chars[0x000D]["uuid"], custom_uuid)
        self.assertEqual(connection["services"][0]["uuid_16"], "0x180F")
        writes = connection["writes"]
        self.assertEqual([(item["operation"], item["handle"], item["characteristic_uuid"]) for item in writes], [
            ("write_request", 0x000B, chars[0x000B]["uuid"]),
            ("signed_write_command", 0x000D, custom_uuid),
        ])
        self.assertEqual([item["value_hex"] for item in writes], ["6f6e", "626c7565"])
        self.assertEqual(writes[1]["value_length"], 4)  # Signed command signature is excluded.
        prepare_writes = connection["prepare_writes"]
        self.assertEqual([(item["operation"], item["handle"], item["characteristic_uuid"]) for item in prepare_writes], [
            ("prepare_write_request", 0x000D, custom_uuid),
        ])
        self.assertEqual(prepare_writes[0]["value_hex"], "677265656e")
        self.assertEqual(prepare_writes[0]["offset"], 2)
        self.assertEqual(result["summary"]["writes"], 2)
        self.assertEqual(result["summary"]["prepare_writes"], 1)
        self.assertIsNone(writes[0]["timestamp_iso_utc"])
        utc = analyze_stream(io.BytesIO(data), utc_offset_minutes=480)["connections"][0]["writes"][0]
        self.assertEqual(utc["timestamp_iso_utc"], "2023-11-14T14:13:20.123456Z")

    def test_advertising_local_name_is_attached_by_address(self):
        address_wire = bytes.fromhex("060504030201")
        ad = bytes([5, 0x09]) + b"Lamp"
        report = bytes([0x02, 1, 0x00, 0x01]) + address_wire + bytes([len(ad)]) + ad + bytes([0xD8])
        data = b"".join([
            record(0x01, event(0x3E, report)),
            record(0x01, connection_complete(0x0040, address_wire)),
        ])
        result = analyze_stream(io.BytesIO(data))
        self.assertEqual(result["advertising_names"][0]["name"], "Lamp")
        self.assertEqual(result["connections"][0]["advertised_name"], "Lamp")

    def test_gatt_device_name_read_is_attached_to_connection(self):
        handle = 0x0040
        request = bytes([0x08, 0x01, 0x00, 0xff, 0xff, 0x00, 0x2a])
        name = b"Ado Light Stick"
        response = bytes([0x09, len(name) + 2, 0x03, 0x00]) + name
        data = b"".join([
            record(0x01, connection_complete(handle, bytes.fromhex("060504030201"))),
            acl(handle, "outgoing", 0x02, l2cap(request)),
            acl(handle, "incoming", 0x02, l2cap(response)),
        ])
        connection = analyze_stream(io.BytesIO(data))["connections"][0]
        self.assertEqual(connection["device_name"], "Ado Light Stick")
        self.assertEqual(connection["device_name_handle"], 0x0003)

    def test_malformed_or_truncated_records_fail_with_record_context(self):
        with self.assertRaisesRegex(PklgError, "truncated 4-byte length"):
            list(iter_records(io.BytesIO(b"\x00\x00")))
        with self.assertRaisesRegex(PklgError, "smaller than the 9-byte header"):
            list(iter_records(io.BytesIO(struct.pack(">I", 8))))
        with self.assertRaisesRegex(PklgError, "truncated body"):
            list(iter_records(io.BytesIO(struct.pack(">I", 9) + b"\x00" * 8)))
        with self.assertRaisesRegex(PklgError, "safety cap"):
            list(iter_records(io.BytesIO(struct.pack(">I", 1024 * 1024 + 1))))
        invalid_microseconds = struct.pack(">I", 9) + struct.pack(">II", 1, 1000000) + b"\x01"
        with self.assertRaisesRegex(PklgError, "invalid microseconds"):
            list(iter_records(io.BytesIO(invalid_microseconds)))

    def test_malformed_hci_acl_and_reserved_boundary_flag_fail(self):
        bad_length_acl = record(0x02, struct.pack("<HH", 0x0040, 2) + b"\x00")
        with self.assertRaisesRegex(PklgError, "HCI ACL length says 2"):
            analyze_stream(io.BytesIO(bad_length_acl))
        reserved_boundary = acl(0x0040, "outgoing", 0x03, l2cap(bytes([0x52, 1, 0, 1])))
        with self.assertRaisesRegex(PklgError, "reserved HCI ACL packet-boundary flag"):
            analyze_stream(io.BytesIO(reserved_boundary))


if __name__ == "__main__":
    unittest.main()
