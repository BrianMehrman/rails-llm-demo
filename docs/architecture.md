# Architecture

## Component Overview

```mermaid
graph TD
    Browser["Browser\n(Turbo Drive + Action Cable)"]
    MC["MessagesController#create"]
    CC["ChatsController"]
    Job["LlmResponseJob\n(SolidQueue, in-process)"]
    LC["LlmClient"]
    LLM["LLM Endpoint\n(Ollama / LM Studio)"]
    PG["PostgreSQL\n(primary + queue + cable)"]
    OTEL["OpenTelemetry\n(Jaeger)"]
    PROM["Prometheus\n(/metrics)"]

    Browser -->|"POST /chats/:id/messages"| MC
    MC -->|"saves user message\ncreates pending assistant message"| PG
    MC -->|"enqueues"| Job
    MC -->|"redirect_to @chat"| CC
    CC -->|"renders show"| Browser
    Browser -.->|"Action Cable subscription\n(Solid Cable over Postgres)"| PG
    Job -->|"reads history"| PG
    Job --> LC
    LC -->|"POST /v1/chat/completions"| LLM
    LLM -->|"response"| LC
    LC -->|"OTEL span + Prometheus histogram"| OTEL
    LC -->|"llm_request_duration_seconds"| PROM
    Job -->|"updates message to complete/error"| PG
    Job -->|"broadcast_replace_to"| Browser
```

---

## Request → Job → Broadcast Sequence

```mermaid
sequenceDiagram
    actor User
    participant Browser
    participant MessagesController
    participant DB as PostgreSQL
    participant Queue as SolidQueue
    participant Job as LlmResponseJob
    participant Client as LlmClient
    participant LLM as LLM Endpoint

    User->>Browser: submit message form
    Browser->>MessagesController: POST /chats/:chat_id/messages

    MessagesController->>DB: create Message(role: user, status: complete)
    MessagesController->>DB: create Message(role: assistant, status: pending, content: "")
    MessagesController->>Queue: LlmResponseJob.perform_later(chat_id, assistant_message_id)
    MessagesController->>Browser: redirect_to @chat (302)

    Browser->>Browser: renders "Thinking…" for pending message

    Queue->>Job: dequeue and execute
    Job->>DB: Chat.find + messages where status=complete
    Job->>Client: LlmClient.new.chat(history)
    Client->>LLM: POST /v1/chat/completions
    LLM-->>Client: response text
    Client-->>Job: response string
    Job->>DB: assistant_msg.update!(content: response, status: complete)
    Job->>Browser: broadcast_replace_to(chat, target: assistant_msg, partial: "chats/message")

    Browser->>Browser: Turbo replaces pending DOM node with real content
```

---

## Data Model

```mermaid
erDiagram
    Chat {
        bigint id PK
        string title "default: 'New Chat', not null"
        datetime created_at
        datetime updated_at
    }

    Message {
        bigint id PK
        bigint chat_id FK
        string role "user | assistant"
        string status "pending | complete | error"
        text content "blank allowed when status=pending only"
        datetime created_at
        datetime updated_at
    }

    Chat ||--o{ Message : "has_many (dependent: destroy)"
```

### Message status lifecycle

```
pending  ──► complete   (LlmResponseJob succeeds)
pending  ──► error      (LlmResponseJob rescues LlmClient::Error)
```

- Only `complete` messages are included in LLM history.
- The view renders "Thinking…" for `pending`; the Turbo broadcast swaps in real content.
- `content` presence is not validated when `status == "pending"`.
