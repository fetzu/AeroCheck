# AeroCheck Landing Page

This is the landing page for [AeroCheck](https://github.com/fetzu/AeroCheck), an iOS flight checklist app for pilot students.

## Viewing the Site

The landing page is deployed at: `https://fetzu.github.io/AeroCheck/`

## Development

This site is built using Jekyll and hosted on GitHub Pages using the [Automatic App Landing Page](https://github.com/emilbaehr/automatic-app-landing-page) template.

### Local Development

```bash
# Install dependencies
bundle install

# Run locally
bundle exec jekyll serve
```

Then visit `http://localhost:4000/AeroCheck/` in your browser.

### Updating Content

- **Features**: Edit the `features` section in `_config.yml`
- **Releases**: Automatically updated by GitHub Actions when new releases are published
- **Privacy Policy**: Edit `_pages/privacypolicy.md`
- **Screenshots**: Replace files in `assets/screenshot/`
- **Video**: Replace files in `assets/videos/`

### Color Scheme

The landing page uses AeroCheck's aviation-inspired dark theme:
- Background: `#141419` (cockpit background)
- Accent: `#D9A633` (aviation gold)
- Secondary: `#1A3366` (aviation blue)
- Success: `#33B34D` (aviation green)

## Credits

- Landing page template: [Automatic App Landing Page](https://github.com/emilbaehr/automatic-app-landing-page) by Emil Baehr
- [Jekyll](https://github.com/jekyll/jekyll)
- [FontAwesome](https://fontawesome.com/)

## License

[MIT License](LICENSE)
