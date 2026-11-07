import unittest

from experiments.e2_claiming.e2_runner import is_approved_loopback_host


class ApprovedLoopbackHostTests(unittest.TestCase):
    def test_accepts_bare_ipv4_loopback(self):
        self.assertTrue(is_approved_loopback_host("127.0.0.1"))

    def test_accepts_ipv4_loopback_with_host_prefix(self):
        self.assertTrue(is_approved_loopback_host("127.0.0.1/32"))

    def test_rejects_non_loopback_addresses(self):
        for address in ("10.0.0.1", "192.168.1.10", "34.120.10.20/32"):
            with self.subTest(address=address):
                self.assertFalse(is_approved_loopback_host(address))

    def test_rejects_other_or_invalid_address_forms(self):
        for address in ("::1", "example.supabase.co", "127.0.0.1/invalid", "", None):
            with self.subTest(address=address):
                self.assertFalse(is_approved_loopback_host(address))


if __name__ == "__main__":
    unittest.main()
