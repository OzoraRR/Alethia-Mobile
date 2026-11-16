# Module islands and roadmaps

Source artwork came from `alethia-islands-v3-static-animated.zip`.

- The six clean, transparent static WebP illustrations live in `app/src/main/res/drawable-nodpi/` and keep their source dimensions: 768×768 for islands and 768×1152 for roadmaps.
- The rough long-streak animation renders are not packaged. `ModuleArtwork` animates the original stills with a restrained vertical float. Islands use 20 staggered fragment emitters and roadmaps use 24 distributed across the visible island layers. Fragments have independent lifetimes, accelerating descent, lateral drift, restrained rotation, chipped silhouettes and three shaded faces. Only a subset appears at once; opacity fades each release in and out.
- Roadmaps crop the top 38% of the artwork and fit the remaining path without distortion, leaving the route open-ended. Categories without practice content use a grayscale, dimmed map with a pixel lock badge.
- On the Phishing roadmap, the unstarted route art is dimmed grayscale and only the lower Courier checkpoint area keeps its original color.
- Progress panels show only the completion count at the right and the progress bar. They do not label this as local progress.
- Each island has one real checkpoint: `courier-sms`, `social-engineering`, or `executable-file`. Signed-in access follows the server; guest access follows separate local practice results. Locked categories remain grayscale; available categories use their original artwork colors.
