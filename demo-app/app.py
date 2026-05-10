import os
import time
import socket
from flask import Flask, jsonify

app = Flask(__name__)

ENV_ID   = os.environ.get("ENV_ID", "unknown")
ENV_NAME = os.environ.get("ENV_NAME", "unknown")
START_TIME = time.time()


@app.route("/")
def index():
    return jsonify({
        "message": f"Hello from {ENV_NAME}!",
        "env_id": ENV_ID,
        "hostname": socket.gethostname(),
        "uptime_seconds": round(time.time() - START_TIME, 2),
    })


@app.route("/health")
def health():
    return jsonify({
        "status": "ok",
        "env_id": ENV_ID,
        "env_name": ENV_NAME,
        "uptime_seconds": round(time.time() - START_TIME, 2),
        "timestamp": time.time(),
    })


@app.route("/info")
def info():
    return jsonify({
        "env_id": ENV_ID,
        "env_name": ENV_NAME,
        "hostname": socket.gethostname(),
        "pid": os.getpid(),
        "started_at": START_TIME,
    })


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 3000))
    app.run(host="0.0.0.0", port=port)
