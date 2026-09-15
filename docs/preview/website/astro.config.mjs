import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// Deployed to GitHub Pages by .github/workflows/website-deploy.yml, which
// passes --site and --base from actions/configure-pages so this file
// needs neither; a local build wants
// `astro build --site https://<owner>.github.io --base /<repo>`.
export default defineConfig({
  integrations: [
    starlight({
      title: 'Night Watchman',
      description: 'Documentation for the night-watchman plugin.',
      social: [
        { icon: 'github', label: 'GitHub', href: 'https://github.com/moneymikeMD/night-watchman' },
      ],
      sidebar: [
        {
          label: 'Getting Started',
          items: [{ autogenerate: { directory: 'getting-started' } }],
        },
        {
          label: 'Guides',
          items: [{ autogenerate: { directory: 'guides' } }],
        },
        {
          label: 'Reference',
          items: [{ autogenerate: { directory: 'reference' } }],
        },
      ],
    }),
  ],
});
