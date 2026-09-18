import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// The deploy workflow passes --site and --base from actions/configure-pages,
// so a LOCAL build needs `astro build --site ... --base /<repo>` to match.
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
