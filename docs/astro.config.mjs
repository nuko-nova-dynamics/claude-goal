// @ts-check
import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";
import mermaid from "astro-mermaid";

export default defineConfig({
  site: "https://nuko-nova-dynamics.github.io",
  base: "/claude-goal",
  integrations: [
    mermaid({ theme: "dark", autoTheme: true }),
    starlight({
      title: "claude-goal",
      logo: {
        src: "./src/assets/icon.svg",
        replacesTitle: false,
      },
      favicon: "/favicon.svg",
      description:
        "Goal-bounded autonomous turns for Claude Code. Set an objective, set a budget, walk away.",
      social: [
        {
          icon: "github",
          label: "GitHub",
          href: "https://github.com/nuko-nova-dynamics/claude-goal",
        },
      ],
      editLink: {
        baseUrl:
          "https://github.com/nuko-nova-dynamics/claude-goal/edit/main/docs/",
      },
      lastUpdated: true,
      pagination: true,
      customCss: ["./src/styles/theme.css"],
      head: [
        { tag: "meta", attrs: { name: "theme-color", content: "#D97757" } },
        {
          tag: "meta",
          attrs: {
            property: "og:image",
            content:
              "https://nuko-nova-dynamics.github.io/claude-goal/social-card.png",
          },
        },
        {
          tag: "meta",
          attrs: {
            property: "og:image:width",
            content: "1536",
          },
        },
        {
          tag: "meta",
          attrs: {
            property: "og:image:height",
            content: "1024",
          },
        },
        {
          tag: "meta",
          attrs: { name: "twitter:card", content: "summary_large_image" },
        },
        {
          tag: "meta",
          attrs: {
            name: "twitter:image",
            content:
              "https://nuko-nova-dynamics.github.io/claude-goal/social-card.png",
          },
        },
      ],
      components: {
        // keep defaults; override later if needed
      },
      sidebar: [
        {
          label: "Start here",
          items: [
            { label: "Overview", slug: "" },
            { label: "Install", slug: "install" },
            { label: "Quickstart", slug: "quickstart" },
          ],
        },
        {
          label: "Concepts",
          items: [
            { label: "How it works", slug: "concepts/how-it-works" },
            { label: "Budgets and caps", slug: "concepts/budgets" },
            { label: "Completion evaluator", slug: "concepts/evaluator" },
            { label: "State and persistence", slug: "concepts/state" },
          ],
        },
        {
          label: "Commands",
          items: [
            { label: "Reference", slug: "commands/reference" },
            { label: "Statusline", slug: "commands/statusline" },
          ],
        },
        {
          label: "Recipes",
          items: [
            { label: "Run a goal under budget", slug: "recipes/budget" },
            { label: "Recover from /compact", slug: "recipes/compact" },
            { label: "Reap orphaned goals", slug: "recipes/cleanup" },
          ],
        },
        {
          label: "Project",
          items: [
            {
              label: "Roadmap",
              link: "https://github.com/nuko-nova-dynamics/claude-goal/blob/main/ROADMAP.md",
              attrs: { target: "_blank" },
            },
            {
              label: "Release notes",
              link: "https://github.com/nuko-nova-dynamics/claude-goal/blob/main/RELEASE_NOTES.md",
              attrs: { target: "_blank" },
            },
            {
              label: "Source on GitHub",
              link: "https://github.com/nuko-nova-dynamics/claude-goal",
              attrs: { target: "_blank" },
            },
          ],
        },
      ],
    }),
  ],
});
