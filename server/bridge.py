# Holds the state the computer posts, and serves it to a browser. Runs beside
# the install server on the next port, and knows nothing about serving Lua.
import json
import threading
import time
from pathlib import Path

from flask import Flask, Response, jsonify, request

PORT = 8081
WEB = Path(__file__).resolve().parent / "web"

app = Flask(__name__)

# The computer is the only writer. It leaves the item list out of a tick when
# nothing changed, so the last one it sent has to survive here.
state = {"items": [], "stats": {}, "output": None, "at": None}
seen = None
version = 0
items_version = 0
pending = []
lock = threading.Condition()


def snapshot():
    """Caller holds the lock."""
    return dict(state, version=version, items_version=items_version,
                age=None if seen is None else time.time() - seen)


@app.post("/tick")
def tick():
    body = request.get_json(silent=True)
    if not isinstance(body, dict):
        return "expected a json object", 400

    global seen, version, items_version
    items = body.pop("items", None)

    with lock:
        if items is not None:
            state["items"] = items
            items_version += 1
        state.update(body)
        seen = time.time()
        version += 1

        commands, pending[:] = list(pending), []
        lock.notify_all()

    return jsonify(commands=commands)


# The browser can ask for items too. Requests wait here until the computer's
# next tick collects them, so there is no point taking one when it has stopped
# ticking -- it would sit in the queue until something restarted.
@app.post("/api/request")
def api_request():
    body = request.get_json(silent=True) or {}
    item, count = body.get("id"), body.get("count")

    if not isinstance(item, str) or not isinstance(count, int) or count < 1:
        return jsonify(error="want an item id and a positive count"), 400

    with lock:
        if seen is None or time.time() - seen > 5:
            return jsonify(error="the computer is not ticking"), 503
        pending.append({"id": item, "count": count})

    return jsonify(queued=count)


@app.get("/api/state")
def api_state():
    with lock:
        return jsonify(snapshot())


@app.get("/api/events")
def api_events():
    def stream():
        seen_version, seen_items = -1, -1

        while True:
            with lock:
                fresh = lock.wait_for(lambda: version != seen_version, timeout=15)

                if fresh:
                    payload = snapshot()
                    # the browser keeps the list it has, the same way the server
                    # keeps the one the computer sent
                    if items_version == seen_items:
                        payload.pop("items")
                    seen_version, seen_items = version, items_version
                else:
                    payload = None

            # never yield holding the lock, or a slow reader stalls every tick
            yield f"data: {json.dumps(payload)}\n\n" if payload else ": keepalive\n\n"

    return Response(stream(), mimetype="text/event-stream",
                    headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})


@app.get("/")
def page():
    # read per request so editing the page does not mean restarting the server
    return Response(WEB.joinpath("index.html").read_text(), mimetype="text/html")


app.run(host="0.0.0.0", port=PORT)
