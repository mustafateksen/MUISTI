"""Token proxy tests (stdlib unittest + FastAPI TestClient; the upstream is replaced by a fake).
Run from nemotron/:  python -I -m unittest eval.test_token_proxy -v   (or: python eval/test_token_proxy.py)"""
import os
import sys
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.environ.update(MUISTI_TOKEN_SECRET="test-secret-0123456789", MUISTI_PAIR_CODE="482913",
                  VERDA_INFERENCE_KEY="dc_REALKEY", MUISTI_TOKEN_TTL="60")

import httpx
from fastapi import FastAPI
from fastapi.testclient import TestClient

import token_proxy as P

SEEN = []


def fake_upstream(req: httpx.Request) -> httpx.Response:
    SEEN.append(req)
    return httpx.Response(200, json={"ok": True, "url": str(req.url)})


class ProxyTest(unittest.TestCase):
    def setUp(self):
        SEEN.clear()
        P._client = httpx.AsyncClient(transport=httpx.MockTransport(fake_upstream))
        app = FastAPI(); app.include_router(P.router)
        self.c = TestClient(app)

    def _token(self):
        sec = self.c.post("/proxy/pair", json={"device_id": "phone-1", "code": "482913"}).json()["device_secret"]
        return self.c.post("/proxy/token", json={"device_id": "phone-1", "device_secret": sec}).json()["token"]

    def test_pair_and_forward_adds_real_key(self):
        t = self._token()
        r = self.c.post("/proxy/llm/v1/chat/completions", json={"model": "m"}, headers={"Authorization": f"Bearer {t}"})
        self.assertEqual(200, r.status_code)
        self.assertEqual("Bearer dc_REALKEY", SEEN[0].headers["authorization"])
        self.assertTrue(str(SEEN[0].url).endswith("/muisti-nemotron/v1/chat/completions"))
        r = self.c.post("/proxy/retrieval/v2/embed", json={}, headers={"Authorization": f"Bearer {t}"})
        self.assertTrue(str(SEEN[1].url).endswith("/muisti-retrieval/v2/embed"))

    def test_wrong_code_and_bad_tokens_are_refused(self):
        self.assertEqual(401, self.c.post("/proxy/pair", json={"device_id": "phone-1", "code": "000000"}).status_code)
        self.assertEqual(401, self.c.post("/proxy/token", json={"device_id": "phone-1", "device_secret": "x"}).status_code)
        self.assertEqual(401, self.c.post("/proxy/llm/v1/chat/completions", json={}).status_code)
        t = self._token()
        forged = t.split(".")[0] + ".AAAA"
        self.assertEqual(401, self.c.post("/proxy/llm/v1/chat/completions", json={}, headers={"Authorization": f"Bearer {forged}"}).status_code)
        self.assertEqual([], SEEN)

    def test_token_expires(self):
        old = P.make_token("phone-1", now=time.time() - 120, ttl=60)
        r = self.c.post("/proxy/llm/v1/chat/completions", json={}, headers={"Authorization": f"Bearer {old}"})
        self.assertEqual(401, r.status_code)
        self.assertEqual([], SEEN)

    def test_only_known_paths(self):
        t = self._token()
        self.assertEqual(404, self.c.post("/proxy/llm/admin", json={}, headers={"Authorization": f"Bearer {t}"}).status_code)

    def test_revoked_device(self):
        t = self._token()
        os.environ["MUISTI_REVOKED"] = "phone-1"
        try:
            r = self.c.post("/proxy/llm/v1/chat/completions", json={}, headers={"Authorization": f"Bearer {t}"})
            self.assertEqual(401, r.status_code)
        finally:
            os.environ["MUISTI_REVOKED"] = ""


if __name__ == "__main__":
    unittest.main(verbosity=2)
