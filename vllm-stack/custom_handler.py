"""Collapse multi-block system prompts into a single leading system message.

vLLM's Qwen3 chat template accepts exactly one system message, and it must be
the first entry. Agentic clients (opencode, Claude Code) routinely send several
system blocks, or place one after the opening user turn; vLLM rejects the whole
request with "System message must be at the beginning."

This runs before the request leaves the proxy: concatenate every system message
in order, drop them from the array, reinsert one system message at index 0.
Requests that are already well-formed are returned untouched, so the hook is a
no-op for well-behaved clients.
"""

from litellm.integrations.custom_logger import CustomLogger

CHAT_CALL_TYPES = ("completion", "acompletion")


def _as_text(content):
    """System content arrives as a plain string or a list of typed blocks."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, str):
                parts.append(block)
            elif isinstance(block, dict) and block.get("type") == "text":
                text = block.get("text")
                if text:
                    parts.append(text)
        return "\n\n".join(parts)
    return "" if content is None else str(content)


class SystemMessageNormalizer(CustomLogger):
    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        if call_type not in CHAT_CALL_TYPES:
            return data

        messages = data.get("messages")
        if not isinstance(messages, list) or not messages:
            return data

        system_parts = []
        rest = []
        for message in messages:
            if isinstance(message, dict) and message.get("role") == "system":
                text = _as_text(message.get("content"))
                if text:
                    system_parts.append(text)
            else:
                rest.append(message)

        if not system_parts:
            return data

        # Already exactly one system message, already in front: leave it alone.
        first = messages[0]
        if len(system_parts) == 1 and isinstance(first, dict) and first.get("role") == "system":
            return data

        merged = {"role": "system", "content": "\n\n".join(system_parts)}
        data["messages"] = [merged] + rest
        return data


proxy_handler_instance = SystemMessageNormalizer()
