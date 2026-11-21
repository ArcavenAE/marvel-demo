# Rung 0g: wardrobe is read-only

Demo: wardrobe content is read from a published release and is not edited in place.

You: ask the agent where wardrobe is read from (`just root` in the wardrobe folder). This rung reads SKIP until a release is published. Run `just lab check 0g`.

## Tools

- just, installed at rung 0a.
- The wardrobe release, once one is published; until then there is nothing to install.

## Expected prompts

- `just root` asks, because only the `just lab` recipes are on the agent's permission list. Answer yes.
