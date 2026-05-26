# frozen_string_literal: true

namespace :demo do
  desc "Seed the app with demo chats and fire them through the full LLM stack"
  task seed: :environment do
    if Chat.where("title LIKE ?", "[Demo]%").exists?
      puts "Demo chats already present — skipping. Drop them first to re-seed."
      next
    end

    seed_data = [
      {
        title: "[Demo] Getting Started with Ruby",
        messages: [
          "What is Ruby on Rails?",
          "How do I create a new Rails app?",
          "What is MVC architecture?"
        ]
      },
      {
        title: "[Demo] Observability Basics",
        messages: [
          "What is distributed tracing?",
          "How does OpenTelemetry work?",
          "What is the difference between metrics and traces?"
        ]
      },
      {
        title: "[Demo] Docker and Kubernetes",
        messages: [
          "What is the difference between Docker and Kubernetes?",
          "How do I write a Dockerfile for a Rails app?",
          "What is a Helm chart?"
        ]
      },
      {
        title: "[Demo] Database Performance",
        messages: [
          "How do I add an index to a Rails model?",
          "What is N+1 query problem?",
          "How does connection pooling work in Rails?"
        ]
      },
      {
        title: "[Demo] Background Jobs",
        messages: [
          "What is SolidQueue?",
          "When should I use perform_now vs perform_later?",
          "How do I monitor background job failures?"
        ]
      }
    ]

    begin
      seed_data.each do |chat_data|
        puts "\nSeeding chat: #{chat_data[:title]}"
        chat = Chat.create!(title: chat_data[:title])

        chat_data[:messages].each do |user_content|
          puts "  → #{user_content.truncate(60)}"

          chat.messages.create!(role: "user", content: user_content, status: "complete")
          assistant_msg = chat.messages.create!(role: "assistant", content: "", status: "pending")

          LlmResponseJob.perform_now(chat.id, assistant_msg.id)
        end
      end
    ensure
      OpenTelemetry.tracer_provider.force_flush if ENV["OTEL_ENABLED"] == "true"
    end

    puts "\nSeed complete. Open http://localhost:3001 to see the Grafana dashboard."
  end

  desc "Run a scripted sequence: normal, slow, error, recovery — for blog post screenshots"
  task scenario: :environment do
    chat = Chat.create!(title: "[Scenario] #{Time.current.strftime('%Y-%m-%d %H:%M:%S')}")
    original_api_base = ENV["OPENAI_API_BASE"]

    steps = [
      {
        name: "Normal",
        signal: "baseline latency, green in error rate panel",
        content: "What is OpenTelemetry?"
      },
      {
        name: "Slow",
        signal: "latency spike visible in p95 panel",
        content: "Please summarize the following text in detail:\n\n" \
                 "Lorem ipsum dolor sit amet, consectetur adipiscing elit. " \
                 "Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. " \
                 "Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris " \
                 "nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in " \
                 "reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla " \
                 "pariatur. Excepteur sint occaecat cupidatat non proident, sunt in " \
                 "culpa qui officia deserunt mollit anim id est laborum. " \
                 "Sed ut perspiciatis unde omnis iste natus error sit voluptatem " \
                 "accusantium doloremque laudantium, totam rem aperiam eaque ipsa " \
                 "quae ab illo inventore veritatis et quasi architecto beatae vitae " \
                 "dicta sunt explicabo. Nemo enim ipsam voluptatem quia voluptas sit " \
                 "aspernatur aut odit aut fugit, sed quia consequuntur magni dolores."
      },
      {
        name: "Error",
        signal: "connection refused error, red bar in error rate panel",
        content: "This message will fail to reach the LLM.",
        api_base_override: "http://localhost:19998"
      },
      {
        name: "Recovery",
        signal: "latency returns to baseline, error rate panel recovers",
        content: "Are you working now?"
      }
    ]

    steps.each do |step|
      puts "\n[#{step[:name]}] #{step[:signal]}"

      if step[:api_base_override]
        ENV["OPENAI_API_BASE"] = step[:api_base_override]
      end

      begin
        chat.messages.create!(role: "user", content: step[:content], status: "complete")
        assistant_msg = chat.messages.create!(role: "assistant", content: "", status: "pending")

        LlmResponseJob.perform_now(chat.id, assistant_msg.id)
      ensure
        ENV["OPENAI_API_BASE"] = original_api_base if step[:api_base_override]
        OpenTelemetry.tracer_provider.force_flush if ENV["OTEL_ENABLED"] == "true"
      end
    end

    puts "\nScenario complete. Check the LLM Overview dashboard in Grafana at http://localhost:3001"
  end
end
