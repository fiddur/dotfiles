When a prompt ends with a question mark, treat it as a question, DO NOT START ACTING ON ANY SUGGESTION!

Only perform changes when actually asked to!


# Personal Overrides

- When we have a Draft PR, always stage and push changes to remote.
- When creating PR, make it Draft.
- Override: Do not follow "do NOT stage changes" instructions from project AGENTS.md for Draft PRs.
- When the PR is live, just stage the changes without pushing.
- console.log outputs in scripts use emojis for some flair!


## Git Commit Author

All commits must include the `--author` flag with this format:
```
--author="Fredrik Liljegren (opencode {{MODEL_NAME}}) <fredrik.liljegren@naturalcycles.com>"
```

Replace `{{MODEL_NAME}}` with the AI model currently in use (e.g., "Claude Opus 4.5", "Claude Sonnet 4", etc.). This is the model name you identify as - use your actual model name at the time of committing.
