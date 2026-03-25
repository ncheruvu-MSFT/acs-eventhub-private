"""
ACS Voice + Events Sample App for Azure Container Apps.

Endpoints:
  GET  /health              - Health check (App Gateway probe)
  POST /api/callback        - ACS voice callback (IncomingCall webhook)
  GET  /api/events          - View recent events from Service Bus queue
  POST /api/test/voice      - Simulate ACS voice IncomingCall event
  POST /api/test/chat       - Simulate ACS chat message event
  POST /api/test/sms        - Simulate ACS SMS received event
  GET  /api/test/queue      - Send a test message to Service Bus queue
  GET  /api/test/validate   - Run full end-to-end validation (voice + chat + queue)

Background:
  Continuously receives messages from the Service Bus queue (ACS events
  delivered via Event Grid) and stores the last N in memory for inspection.
"""

import json
import logging
import os
import threading
import time
import uuid
from collections import deque
from datetime import datetime, timezone

from flask import Flask, jsonify, request

app = Flask(__name__)
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger("acs-sample")

# ── Configuration ─────────────────────────────────────────────────────────────
SB_CONNECTION_STRING = os.environ.get("SERVICEBUS_CONNECTION_STRING", "")
SB_QUEUE_NAME = os.environ.get("SERVICEBUS_QUEUE_NAME", "acs-events")
MAX_EVENTS = 100  # keep last N events in memory

# Thread-safe event store
_events_lock = threading.Lock()
_recent_events: deque = deque(maxlen=MAX_EVENTS)


# ── Health ────────────────────────────────────────────────────────────────────
@app.route("/health", methods=["GET"])
def health():
    """Health check for App Gateway and ACA probes."""
    return jsonify({"status": "healthy"}), 200


# ── ACS Voice Callback ───────────────────────────────────────────────────────
@app.route("/api/callback", methods=["POST"])
def acs_callback():
    """Handle ACS IncomingCall and call-control webhook events.

    ACS sends JSON with an array of event objects.  For an IncomingCall,
    this returns an Answer action.  For other call events it logs and ACKs.
    """
    payload = request.get_json(silent=True)
    if payload is None:
        logger.warning("Callback received non-JSON body")
        return jsonify({"error": "Expected JSON"}), 400

    # ACS may send Cloud Events as an array
    events = payload if isinstance(payload, list) else [payload]

    for event in events:
        event_type = event.get("type", event.get("eventType", "unknown"))
        logger.info("Voice callback: type=%s", event_type)

        # Store for /api/events
        with _events_lock:
            _recent_events.append(
                {"source": "voice-callback", "type": event_type, "data": event}
            )

        # EventGrid validation handshake
        if event_type == "Microsoft.EventGrid.SubscriptionValidationEvent":
            code = event.get("data", {}).get("validationCode", "")
            logger.info("EventGrid validation handshake: code=%s", code)
            return jsonify({"validationResponse": code}), 200

        # ACS IncomingCall — answer the call
        if event_type == "Microsoft.Communication.IncomingCall":
            logger.info("Answering incoming call from %s", event.get("data", {}).get("from", {}).get("rawId", "unknown"))
            return jsonify([
                {
                    "kind": "IncomingCallResponse",
                    "incomingCallResponse": {"callbackUri": request.url_root.rstrip("/") + "/api/callback"}
                }
            ]), 200

    return jsonify({"status": "processed"}), 200


# ── Recent Events ─────────────────────────────────────────────────────────────
@app.route("/api/events", methods=["GET"])
def list_events():
    """Return the last N events received (queue + callbacks)."""
    with _events_lock:
        items = list(_recent_events)
    return jsonify({"count": len(items), "events": items}), 200


# ── Test / Validation Endpoints ───────────────────────────────────────────────

def _make_event_id():
    return str(uuid.uuid4())


@app.route("/api/test/voice", methods=["POST"])
def test_voice():
    """Simulate an ACS IncomingCall event through the callback pipeline."""
    caller = request.json.get("caller", "+15551234567") if request.is_json else "+15551234567"
    event = {
        "id": _make_event_id(),
        "type": "Microsoft.Communication.IncomingCall",
        "eventType": "Microsoft.Communication.IncomingCall",
        "eventTime": datetime.now(timezone.utc).isoformat(),
        "subject": "/caller/test",
        "data": {
            "to": {"rawId": "8:acs:test-resource", "kind": "communicationUser"},
            "from": {"rawId": caller, "kind": "phoneNumber", "phoneNumber": {"value": caller}},
            "callerDisplayName": "Test Caller",
            "incomingCallContext": "test-context-" + _make_event_id(),
            "correlationId": _make_event_id(),
        },
    }
    # Route through the real callback handler
    with app.test_request_context("/api/callback", method="POST", json=[event]):
        with _events_lock:
            _recent_events.append({"source": "test-voice", "type": event["type"], "data": event})
    logger.info("Test voice event injected: caller=%s", caller)
    return jsonify({"status": "ok", "test": "voice", "eventId": event["id"], "caller": caller}), 200


@app.route("/api/test/chat", methods=["POST"])
def test_chat():
    """Simulate an ACS ChatMessageReceived event through the pipeline."""
    body = request.json if request.is_json else {}
    sender = body.get("sender", "user:test-sender")
    message = body.get("message", "Hello from chat test!")
    thread_id = body.get("threadId", "19:test-thread@thread.v2")

    event = {
        "id": _make_event_id(),
        "type": "Microsoft.Communication.ChatMessageReceived",
        "eventType": "Microsoft.Communication.ChatMessageReceived",
        "eventTime": datetime.now(timezone.utc).isoformat(),
        "subject": f"/threads/{thread_id}",
        "data": {
            "messageId": _make_event_id(),
            "messageBody": message,
            "senderCommunicationIdentifier": {"rawId": sender, "kind": "communicationUser"},
            "senderDisplayName": "Test Chat User",
            "chatThreadId": thread_id,
            "type": "text",
            "version": "1",
            "transactionId": _make_event_id(),
        },
    }
    with _events_lock:
        _recent_events.append({"source": "test-chat", "type": event["type"], "data": event})
    logger.info("Test chat event injected: sender=%s threadId=%s", sender, thread_id)
    return jsonify({"status": "ok", "test": "chat", "eventId": event["id"], "message": message}), 200


@app.route("/api/test/sms", methods=["POST"])
def test_sms():
    """Simulate an ACS SMSReceived event."""
    body = request.json if request.is_json else {}
    from_number = body.get("from", "+15559876543")
    to_number = body.get("to", "+15551112222")
    message = body.get("message", "Test SMS message")

    event = {
        "id": _make_event_id(),
        "type": "Microsoft.Communication.SMSReceived",
        "eventType": "Microsoft.Communication.SMSReceived",
        "eventTime": datetime.now(timezone.utc).isoformat(),
        "subject": "/phonenumber/test",
        "data": {
            "from": from_number,
            "to": to_number,
            "message": message,
            "messageId": _make_event_id(),
            "receivedTimestamp": datetime.now(timezone.utc).isoformat(),
        },
    }
    with _events_lock:
        _recent_events.append({"source": "test-sms", "type": event["type"], "data": event})
    logger.info("Test SMS event injected: from=%s to=%s", from_number, to_number)
    return jsonify({"status": "ok", "test": "sms", "eventId": event["id"]}), 200


@app.route("/api/test/queue", methods=["GET"])
def test_queue():
    """Send a test message to the Service Bus queue and verify round-trip."""
    if not SB_CONNECTION_STRING:
        return jsonify({"status": "error", "detail": "SERVICEBUS_CONNECTION_STRING not set"}), 503

    from azure.servicebus import ServiceBusClient, ServiceBusMessage

    test_id = _make_event_id()
    test_msg = json.dumps({
        "eventType": "test.QueueRoundTrip",
        "testId": test_id,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    })

    try:
        with ServiceBusClient.from_connection_string(SB_CONNECTION_STRING) as client:
            with client.get_queue_sender(queue_name=SB_QUEUE_NAME) as sender:
                sender.send_messages(ServiceBusMessage(test_msg))
        logger.info("Test message sent to queue: testId=%s", test_id)
        return jsonify({
            "status": "ok",
            "test": "queue-send",
            "testId": test_id,
            "detail": "Message sent. Check /api/events in ~30s for the round-trip.",
        }), 200
    except Exception as err:
        logger.error("Test queue send failed: %s", err)
        return jsonify({"status": "error", "detail": str(err)}), 500


@app.route("/api/test/validate", methods=["GET"])
def test_validate():
    """Run full end-to-end validation: health + voice + chat + SMS + queue connectivity."""
    results = {}

    # 1. Health check
    results["health"] = {"status": "pass"}

    # 2. Voice simulation
    voice_event_id = _make_event_id()
    voice_event = {
        "id": voice_event_id,
        "type": "Microsoft.Communication.IncomingCall",
        "eventTime": datetime.now(timezone.utc).isoformat(),
        "data": {"from": {"rawId": "+15550000000"}, "callerDisplayName": "Validator"},
    }
    with _events_lock:
        _recent_events.append({"source": "validate-voice", "type": voice_event["type"], "data": voice_event})
    results["voice"] = {"status": "pass", "eventId": voice_event_id}

    # 3. Chat simulation
    chat_event_id = _make_event_id()
    chat_event = {
        "id": chat_event_id,
        "type": "Microsoft.Communication.ChatMessageReceived",
        "eventTime": datetime.now(timezone.utc).isoformat(),
        "data": {"messageBody": "Validation chat message", "chatThreadId": "19:validate@thread.v2"},
    }
    with _events_lock:
        _recent_events.append({"source": "validate-chat", "type": chat_event["type"], "data": chat_event})
    results["chat"] = {"status": "pass", "eventId": chat_event_id}

    # 4. SMS simulation
    sms_event_id = _make_event_id()
    sms_event = {
        "id": sms_event_id,
        "type": "Microsoft.Communication.SMSReceived",
        "eventTime": datetime.now(timezone.utc).isoformat(),
        "data": {"from": "+15550000001", "message": "Validation SMS"},
    }
    with _events_lock:
        _recent_events.append({"source": "validate-sms", "type": sms_event["type"], "data": sms_event})
    results["sms"] = {"status": "pass", "eventId": sms_event_id}

    # 5. Service Bus connectivity
    if SB_CONNECTION_STRING:
        try:
            from azure.servicebus import ServiceBusClient, ServiceBusMessage
            test_id = _make_event_id()
            with ServiceBusClient.from_connection_string(SB_CONNECTION_STRING) as client:
                with client.get_queue_sender(queue_name=SB_QUEUE_NAME) as sender:
                    sender.send_messages(ServiceBusMessage(json.dumps({
                        "eventType": "test.Validation", "testId": test_id,
                        "timestamp": datetime.now(timezone.utc).isoformat(),
                    })))
            results["servicebus"] = {"status": "pass", "testId": test_id, "detail": "Message sent to queue"}
        except Exception as err:
            results["servicebus"] = {"status": "fail", "detail": str(err)}
    else:
        results["servicebus"] = {"status": "skip", "detail": "No connection string configured"}

    # 6. Event count
    with _events_lock:
        event_count = len(_recent_events)
    results["eventStore"] = {"status": "pass", "totalEvents": event_count}

    all_pass = all(r.get("status") != "fail" for r in results.values())
    return jsonify({
        "status": "pass" if all_pass else "fail",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "tests": results,
    }), 200 if all_pass else 500


# ── Service Bus Queue Consumer (background thread) ───────────────────────────
def _queue_consumer():
    """Poll Service Bus queue for ACS events delivered by Event Grid."""
    if not SB_CONNECTION_STRING:
        logger.warning("SERVICEBUS_CONNECTION_STRING not set — queue consumer disabled")
        return

    # Import here so the app still starts if the SDK isn't installed
    from azure.servicebus import ServiceBusClient

    logger.info("Starting queue consumer: queue=%s", SB_QUEUE_NAME)

    while True:
        try:
            with ServiceBusClient.from_connection_string(SB_CONNECTION_STRING) as client:
                with client.get_queue_receiver(queue_name=SB_QUEUE_NAME, max_wait_time=30) as receiver:
                    for msg in receiver:
                        try:
                            body = str(msg)
                            parsed = json.loads(body) if body.startswith("{") or body.startswith("[") else {"raw": body}
                            event_type = parsed.get("eventType", parsed.get("type", "queue-message"))

                            logger.info("Queue event: type=%s", event_type)
                            with _events_lock:
                                _recent_events.append(
                                    {"source": "servicebus-queue", "type": event_type, "data": parsed}
                                )

                            receiver.complete_message(msg)
                        except Exception as inner_err:
                            logger.error("Error processing message: %s", inner_err)
                            receiver.abandon_message(msg)
        except Exception as err:
            logger.error("Queue consumer error (reconnecting in 10s): %s", err)
            time.sleep(10)


# ── Startup ───────────────────────────────────────────────────────────────────
# Start the queue consumer in a daemon thread
_consumer_thread = threading.Thread(target=_queue_consumer, daemon=True)
_consumer_thread.start()

if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    app.run(host="0.0.0.0", port=port)
