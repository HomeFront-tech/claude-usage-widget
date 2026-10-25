# Buddy feedback Worker

This Cloudflare Worker accepts `POST /feedback` from Buddy's What's New window and emails a rating or idea to the owner. It validates the five JSON fields, limits requests by IP to three per 60 seconds, and sends plain text through Cloudflare Email Service. It does not include any email address or secret in the repository.

## Owner setup

1. Enable Email Sending on a domain you own in Cloudflare.
2. From this directory, set the recipient and sender with `npx wrangler secret put FEEDBACK_TO` and `npx wrangler secret put FEEDBACK_FROM`. The sender must use your enabled domain.
3. Run `npx wrangler deploy`.
4. Paste the resulting `https://…workers.dev/feedback` URL into `whatsnew.lua`'s `FEEDBACK_URL` constant.

Test the deployed URL with a placeholder address and URL replaced by your own:

```sh
curl -i https://buddy-feedback.example.workers.dev/feedback \
  -H 'Content-Type: application/json' \
  -d '{"rating":4,"idea":"Make Buddy wave","reply_to":"person@example.com","version":"1.7.0","macos":"15.1"}'
```

The `send_email` and `ratelimits` binding shapes in `wrangler.jsonc` come from Cloudflare's documentation. They remain unverified against the owner's account until the first deploy.

Run the local tests with `node --test test`. They use fake bindings and make no network calls.
