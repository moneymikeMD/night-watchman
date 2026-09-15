import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// Scaffold only — no publisher configured yet. Content moves in
// separately; the deploy workflow lives at
// .github/workflows/website-deploy.yml.
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
