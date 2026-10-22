# sanitize-keys

Proves: bin/sanitize finds the keys in common use (OpenAI project, service-account, admin and legacy keys, Anthropic keys, Slack bot, user and app tokens, Google API keys, GitLab tokens, Stripe restricted keys and webhook secrets, AWS temporary key ids, encrypted and PGP private keys, and an env-file or compose-list NAME_PASSWORD=value, quoted or not), leaves each one's look-alike, placeholder and redacted form alone, never fails on its own source as an installed copy or the plugin carries it, and scans a long line with no spaces in about the time it scans a short one.
