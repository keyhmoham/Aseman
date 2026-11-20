import json
import re


class Scripted:
    """An agent that answers each TASK from a script, and records what it was asked."""

    def __init__(self, **replies):
        self.replies = {k: (list(v) if isinstance(v, list) else v) for k, v in replies.items()}
        self.calls: list[tuple[str, dict, list]] = []

    async def ask(self, prompt, history):
        task = re.match(r"TASK: (\w+)", prompt).group(1)
        data = json.loads(prompt.split("DATA:\n", 1)[1].split("\n\nReply with", 1)[0])
        self.calls.append((task, data, history))
        r = self.replies[task]
        if isinstance(r, list):
            r = r.pop(0) if len(r) > 1 else r[0]
        if callable(r):
            r = r(data)
        if isinstance(r, Exception):
            raise r
        return r if isinstance(r, str) else json.dumps(r, ensure_ascii=False)

    @property
    def tasks(self):
        return [c[0] for c in self.calls]
