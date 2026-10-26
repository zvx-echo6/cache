# Cache brand record

The source of the Cache branding: the GPT prompts and how to make a new asset ([PROMPTS.md](PROMPTS.md)), the
branding board it is matched to (`reference/`), the images exactly as GPT named them (`gpt-originals/`), and the same
images renamed by asset number (`source/`, the input of the app build).

The app's icons, splash, wordmarks and module tiles are generated from `source/` by `app/tool/brand_assets.dart`
(run from `app/`: `dart run tool/brand_assets.dart`).
