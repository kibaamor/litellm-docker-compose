#!/usr/bin/env bash

# shellcheck disable=SC1091
source .env

TEST_MODEL="${MODEL:-databricks-gpt-5-5}"
case "$LITELLM_BIND_ADDRESS" in
  0.0.0.0|::) TEST_ADDRESS="localhost" ;;
  *) TEST_ADDRESS="${LITELLM_BIND_ADDRESS:-127.0.0.1}" ;;
esac
TEST_PORT="${LITELLM_PORT:-4000}"

printf "Test LiteLLM is running\n"
curl -sS "http://${TEST_ADDRESS}:${TEST_PORT}/v1/models" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq

printf "\n\nTest LiteLLM chat completions\n"
curl -sS "http://${TEST_ADDRESS}:${TEST_PORT}/v1/chat/completions" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "'"$TEST_MODEL"'",
    "messages": [
      {
        "role": "user",
        "content": "Hello"
      }
    ]
  }' | jq

printf "\n\nTest LiteLLM streaming chat completions\n"
curl -sS -N "http://${TEST_ADDRESS}:${TEST_PORT}/v1/chat/completions" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "'"$TEST_MODEL"'",
    "messages": [
      {
        "role": "user",
        "content": "Explain Kubernetes in 100 words."
      }
    ],
    "stream": true
  }'

printf "\n\nTest LiteLLM tool-augmented chat completions\n"
curl -sS "http://${TEST_ADDRESS}:${TEST_PORT}/v1/chat/completions" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "'"$TEST_MODEL"'",
    "messages": [
      {
        "role": "user",
        "content": "What is the weather in Singapore?"
      }
    ],
    "tools": [
      {
        "type": "function",
        "function": {
          "name": "get_weather",
          "description": "Get weather for a city",
          "parameters": {
            "type": "object",
            "properties": {
              "city": {
                "type": "string"
              }
            },
            "required": [
              "city"
            ]
          }
        }
      }
    ],
    "tool_choice": "auto"
  }' | jq
