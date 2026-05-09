import base64
import http.server
import json
import os
import time

PORT = int(os.environ.get("PORT", "8080"))
BIND = os.environ.get("BIND_ADDRESS", "0.0.0.0")
AUTH_MODE = os.environ.get("AUTH_MODE", "none")
REQUIRED_SCOPE = os.environ.get("REQUIRED_SCOPE", "write:model-registry")

models = []


def decode_jwt_claims(token):
    try:
        payload = token.split(".")[1]
        padding = 4 - len(payload) % 4
        if padding != 4:
            payload += "=" * padding
        return json.loads(base64.urlsafe_b64decode(payload))
    except Exception:
        return None


class RegistryHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def send_json(self, status, data):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
        self.end_headers()
        self.wfile.write(json.dumps(data, indent=2).encode())

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
        self.end_headers()

    def do_GET(self):
        if self.path == "/health":
            self.send_json(200, {"status": "ok", "service": "model-registry"})
            return
        if self.path == "/models":
            self.send_json(200, {"models": models})
            return
        self.send_json(200, {"service": "model-registry", "models_count": len(models)})

    def do_POST(self):
        if self.path != "/write":
            self.send_json(404, {"error": "not found"})
            return

        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode() if content_length > 0 else "{}"
        try:
            data = json.loads(body)
        except json.JSONDecodeError:
            data = {}

        if AUTH_MODE == "check-scope":
            auth_header = self.headers.get("Authorization", "")
            if not auth_header.startswith("Bearer "):
                self.send_json(401, {"error": "unauthorized", "message": "No bearer token provided"})
                return

            claims = decode_jwt_claims(auth_header[7:])
            if claims:
                scopes = claims.get("scope", "")
                if REQUIRED_SCOPE not in scopes:
                    self.send_json(403, {
                        "error": "forbidden",
                        "message": f"Missing required scope: {REQUIRED_SCOPE}",
                        "caller_scopes": scopes,
                        "caller_subject": claims.get("sub", "unknown"),
                        "caller_actor": claims.get("act", {}).get("sub", "none"),
                    })
                    return

        entry = {
            "model_name": data.get("model_name", "unnamed"),
            "version": data.get("version", "0.0"),
            "written_by": data.get("written_by", "unknown"),
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        models.append(entry)

        caller = "unknown"
        auth_header = self.headers.get("Authorization", "")
        if auth_header.startswith("Bearer "):
            claims = decode_jwt_claims(auth_header[7:])
            if claims:
                caller = claims.get("sub", "unknown")

        print(f"[model-registry] WRITE accepted from {caller}: {entry['model_name']} v{entry['version']}", flush=True)
        self.send_json(200, {"status": "written", "entry": entry, "total_models": len(models)})


def main():
    server = http.server.HTTPServer((BIND, PORT), RegistryHandler)
    print(f"[model-registry] listening on {BIND}:{PORT}", flush=True)
    print(f"[model-registry] auth_mode: {AUTH_MODE}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()


if __name__ == "__main__":
    main()
