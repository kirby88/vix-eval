## Implementation Plan: French (fr) Language Support

### Overview

The i18n system lives entirely in `/workspace/ui/src/i18n/`. Adding French requires changes to 5 existing files and 1 new file, following the exact patterns established by Spanish (`es.ts`) and Brazilian Portuguese (`pt-BR.ts`) as the most complete reference locales.

### Files to Change

**1. Create `/workspace/ui/src/i18n/locales/fr.ts`** (new file)

Export a `fr` constant of type `TranslationMap`. Model it on `es.ts` (full cron section) and `pt-BR.ts` (has the extended tabs/subtitles keys added more recently). The file must cover every key present in `en.ts`:
- `common` (health, ok, online, offline, connect, refresh, enabled, disabled, na, version, docs, theme, resources, search)
- `nav` (chat, control, agent, settings, expand, collapse, resize)
- `tabs` (all 18 keys including the newer ones: communications, appearance, automation, infrastructure, aiAgents)
- `subtitles` (matching all tab keys)
- `overview` (access, snapshot, stats, notes, auth, pairing, insecure, connection, cards, attention, eventLog, logTail, quickActions, palette)
- `login` (subtitle, passwordPlaceholder)
- `chat` (disconnected, refreshTitle, thinkingToggle, toolCallsToggle, focusToggle, hideCronSessions, showCronSessions, showCronSessionsHidden, onboardingDisabled)
- `languages` (all 7 entries including the new `fr` key for French itself)
- `cron` (summary, jobs, runs, form, jobList, jobDetail, jobState, runEntry, errors) - full section as in `es.ts`

The export name is `fr` (lowercase, matching the locale identifier, consistent with `de` and `es`).

**2. Update `/workspace/ui/src/i18n/lib/types.ts`**

Change the `Locale` type union from:
```
export type Locale="en"|"zh-CN"|"zh-TW"|"pt-BR"|"de"|"es";
```
to:
```
export type Locale="en"|"zh-CN"|"zh-TW"|"pt-BR"|"de"|"es"|"fr";
```

**3. Update `/workspace/ui/src/i18n/lib/registry.ts`**

Three additions:

a) Add `"fr"` to `LAZY_LOCALES`:
```
const LAZY_LOCALES:readonly LazyLocale[]=["zh-CN","zh-TW","pt-BR","de","es","fr"];
```

b) Add entry to `LAZY_LOCALE_REGISTRY`:
```
fr:{exportName:"fr",loader:()=>import("../locales/fr.ts"),},
```

c) Add a `fr` branch in `resolveNavigatorLocale`:
```
if(navLang.startsWith("fr")){return"fr";}
```
This branch should appear before the final `return DEFAULT_LOCALE` fallback, consistent with how `de` and `es` are handled.

**4. Update `/workspace/src/i18n/registry.test.ts`**

The test at line that reads:
```
expect(SUPPORTED_LOCALES).toEqual(["en","zh-CN","zh-TW","pt-BR","de","es"]);
```
must be updated to:
```
expect(SUPPORTED_LOCALES).toEqual(["en","zh-CN","zh-TW","pt-BR","de","es","fr"]);
```

Also add a `resolveNavigatorLocale` assertion for French:
```
expect(resolveNavigatorLocale("fr-FR")).toBe("fr");
```
in the "resolves browser locale fallbacks" test block alongside the existing `de-DE`, `es-ES`, etc. assertions.

Also add a lazy locale load assertion for French in "loads lazy locale translations from the registry":
```
const fr=await loadLazyLocaleTranslation("fr");
expect(getNestedTranslation(fr,"common","health")).toBe("Santé");
```

**5. Update all existing locale files to add `fr` to their `languages` section**

Each existing non-English locale file has a `languages` block listing all supported languages. All 5 need a new `fr` entry:

- `/workspace/ui/src/i18n/locales/de.ts`: Add `fr:"Französisch (French)"` (or `fr:"Französisch"`)
- `/workspace/ui/src/i18n/locales/es.ts`: Add `fr:"Francés (French)"` (or `fr:"Francés"`)
- `/workspace/ui/src/i18n/locales/pt-BR.ts`: Add `fr:"Français (Francês)"` (or `fr:"Francês (Français)"`)
- `/workspace/ui/src/i18n/locales/zh-CN.ts`: Add `fr:"Français (法语)"` (or `fr:"法语 (Français)"`)
- `/workspace/ui/src/i18n/locales/zh-TW.ts`: Add `fr:"Français (法語)"` (or `fr:"法語 (Français)"`)
- `/workspace/ui/src/i18n/locales/en.ts`: Add `fr:"Français (French)"` to the `languages` section

**6. Create a git branch**

Before implementing, create a new branch from the current HEAD:
```
git checkout -b feat/fr-i18n
```
This produces a PR-ready branch named `feat/fr-i18n`.

### Translation Content for `fr.ts`

Key French translations to use (professional/formal register, consistent with other locales):

- `common.health` = `"Santé"` (this is what the test will assert)
- `common.ok` = `"OK"`
- `common.online` = `"En ligne"`
- `common.offline` = `"Hors ligne"`
- `common.connect` = `"Connecter"`
- `common.refresh` = `"Actualiser"`
- `common.enabled` = `"Activé"`
- `common.disabled` = `"Désactivé"`
- `common.na` = `"n/d"` (non disponible, or `"n/a"` is also acceptable)
- `common.version` = `"Version"`
- `common.docs` = `"Documentation"`
- `common.theme` = `"Thème"`
- `common.resources` = `"Ressources"`
- `common.search` = `"Rechercher"`
- `nav.settings` = `"Paramètres"`
- `overview.access.title` = `"Accès à la passerelle"`
- `overview.access.language` = `"Langue"`
- `languages.fr` = `"Français"` (self-reference, no parenthetical needed)
- `languages.en` = `"Anglais (English)"`
- `languages.de` = `"Deutsch (Allemand)"`
- `languages.es` = `"Español (Espagnol)"`
- `languages.ptBR` = `"Português (Portugais brésilien)"`
- `languages.zhCN` = `"简体中文 (Chinois simplifié)"`
- `languages.zhTW` = `"繁體中文 (Chinois traditionnel)"`

### Sequencing

1. Create branch
2. Create `fr.ts` (largest single change, no dependencies)
3. Update `types.ts` (simple union addition, needed for TypeScript to accept `"fr"` as a `Locale`)
4. Update `registry.ts` (depends on `types.ts` compiling cleanly)
5. Update `en.ts` and the 5 other locale files to add `fr` to their `languages` section
6. Update `registry.test.ts` to include `fr` in all relevant assertions

### Potential Challenges

- The `SUPPORTED_LOCALES` test is an exact `.toEqual()` match on an ordered array. The order matters: `"fr"` must be appended at the end, after `"es"`.
- `pt-BR.ts` has more keys than `de.ts` or `es.ts` (it includes `toolCallsToggle` in chat and the full connection/cards/attention/eventLog/logTail/quickActions/palette subsections). The `fr.ts` file should match the most complete locale (`en.ts`) to avoid silent fallbacks.
- `en.ts` also has `common.theme` and `nav.resize` and `tabs.communications/appearance/automation/infrastructure/aiAgents` which some older locale files are missing. The `fr.ts` should include all of these.

### Critical Files for Implementation

- `/workspace/ui/src/i18n/locales/fr.ts` - New French translation file to create (largest change)
- `/workspace/ui/src/i18n/lib/types.ts` - Add `"fr"` to the `Locale` union type
- `/workspace/ui/src/i18n/lib/registry.ts` - Register `fr` in lazy loaders and navigator resolution
- `/workspace/src/i18n/registry.test.ts` - Update test assertions to include `fr`
- `/workspace/ui/src/i18n/locales/en.ts` - Add `fr` entry to `languages` section (pattern to follow for all other locale files)