---
name: commit-message-helper
description: Write a clear conventional-commit message for the staged changes. Use when the user asks for a commit message.
---

# Commit message helper

1. Run `git diff --staged` to see the staged changes.
2. Pick a conventional-commit type: feat, fix, docs, refactor, test or chore.
3. Write a subject line under 72 characters in the imperative mood.
4. Add a short body explaining why the change was made, if it is not obvious.
5. Show the message to the user. Do not commit unless they ask.
