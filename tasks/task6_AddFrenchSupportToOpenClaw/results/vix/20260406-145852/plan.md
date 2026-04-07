## Implementation Plan: French (fr) Language Support

### Overview

The codebase uses a lazy-loaded i18n system in `/workspace/ui/src/i18n/`. Adding French requires changes to four files and a new locale file, following the exact same pattern as existing locales (German, Spanish, pt-BR, zh-CN, zh-TW).

### Architecture Understanding

The i18n system works as follows:

1. **`/workspace/ui/src/i18n/lib/types.ts`** — defines the `Locale` union type and `TranslationMap` interface
2. **`/workspace/ui/src/i18n/lib/registry.ts`** — registers lazy loaders for all non-English locales, exposes `SUPPORTED_LOCALES`, and implements `resolveNavigatorLocale` for browser language detection
3. **`/workspace/ui/src/i18n/locales/en.ts`** — the canonical English source of truth; all other locales translate from this
4. **`/workspace/ui/src/i18n/locales/*.ts`** — one file per locale, exporting a `TranslationMap`
5. **`/workspace/src/i18n/registry.test.ts`** — tests that `SUPPORTED_LOCALES` matches a hardcoded list, tests `resolveNavigatorLocale`, and tests that lazy-loaded locales have specific translation values
6. **`/workspace/ui/src/i18n/test/translate.test.ts`** — tests the translate module behavior

The test at line 11 of `/workspace/src/i18n/registry.test.ts` explicitly asserts:
```
expect(SUPPORTED_LOCALES).toEqual(["en","zh-CN","zh-TW","pt-BR","de","es"]);
```
This test **must be updated** to include `"fr"` or it will fail after adding French support.

### Step-by-Step Plan

**Step 1: Create `/workspace/ui/src/i18n/locales/fr.ts`**

Create a complete French translation file following the exact same structure as `es.ts` (which is the most complete non-Chinese locale). The file must:
- Export `const fr: TranslationMap`
- Translate all keys present in `en.ts`: `common`, `nav`, `tabs`, `subtitles`, `overview` (with all nested keys including `access`, `snapshot`, `stats`, `notes`, `auth`, `pairing`, `insecure`, `connection`, `cards`, `attention`, `eventLog`, `logTail`, `quickActions`, `palette`), `login`, `chat`, `languages`, and the full `cron` section (with `summary`, `jobs`, `runs`, `form`, `jobList`, `jobDetail`, `jobState`, `runEntry`, `errors`)
- In the `languages` section, include a French-language name for each supported locale plus the new `fr` entry:
  - `en: "Anglais (English)"`
  - `zhCN: "Chinois simplifié (简体中文)"`
  - `zhTW: "Chinois traditionnel (繁體中文)"`
  - `ptBR: "Portugais brésilien (Português)"`
  - `de: "Allemand (Deutsch)"`
  - `es: "Espagnol (Español)"`
  - `fr: "Français"`
- Include the `// pragma: allowlist secret` comment on the password line (matching existing pattern in `de.ts` and `es.ts`)

**Step 2: Update `/workspace/ui/src/i18n/lib/types.ts`**

Add `"fr"` to the `Locale` union type. Current value:
```
export type Locale="en"|"zh-CN"|"zh-TW"|"pt-BR"|"de"|"es";
```
New value:
```
export type Locale="en"|"zh-CN"|"zh-TW"|"pt-BR"|"de"|"es"|"fr";
```

**Step 3: Update `/workspace/ui/src/i18n/lib/registry.ts`**

Three changes are needed:

a) Add `"fr"` to `LAZY_LOCALES`:
```
const LAZY_LOCALES:readonly LazyLocale[]=["zh-CN","zh-TW","pt-BR","de","es","fr"];
```

b) Add the `fr` entry to `LAZY_LOCALE_REGISTRY`:
```
fr:{exportName:"fr",loader:()=>import("../locales/fr.ts"),},
```

c) Add French browser language detection to `resolveNavigatorLocale`:
```
if(navLang.startsWith("fr")){return"fr";}
```
This should be added in alphabetical order, before the final `return DEFAULT_LOCALE` fallback.

**Step 4: Update `/workspace/src/i18n/registry.test.ts`**

Update the hardcoded locale list assertion from:
```
expect(SUPPORTED_LOCALES).toEqual(["en","zh-CN","zh-TW","pt-BR","de","es"]);
```
to:
```
expect(SUPPORTED_LOCALES).toEqual(["en","zh-CN","zh-TW","pt-BR","de","es","fr"]);
```

Also add a `resolveNavigatorLocale` test case for French:
```
expect(resolveNavigatorLocale("fr-FR")).toBe("fr");
```

And add a French translation load assertion in the "loads lazy locale translations from the registry" test:
```
const fr=await loadLazyLocaleTranslation("fr");
expect(getNestedTranslation(fr,"common","health")).toBe("Santé");
expect(getNestedTranslation(fr,"languages","de")).toBe("Allemand (Deutsch)");
```

**Step 5: Create the PR-ready git branch**

After all file modifications are complete:
1. Create and check out a new branch: `git checkout -b feat/french-locale`
2. Stage the changes: `git add` the four modified/created files
3. Commit with a descriptive message: `git commit -m "feat(i18n): add French (fr) locale support"`

### Key Translation Decisions

- `common.health` → `"Santé"` (used in test assertions)
- `languages.de` → `"Allemand (Deutsch)"` (used in test assertions)
- The `// pragma: allowlist secret` comment must be preserved as-is on the password line (it is a security scanner annotation)
- All technical terms like `WebSocket`, `Tailscale`, `Cron`, `Gateway`, `HTTP`, `HTTPS`, `IANA` remain untranslated
- Placeholders like `{time}`, `{count}`, `{shown}`, `{total}`, `{rel}`, `{command}`, `{url}`, `{config}` must be preserved verbatim

### Test Impact

After implementation, the following tests must pass:
- `src/i18n/registry.test.ts` — requires updating the hardcoded locale list and adding French-specific assertions
- `ui/src/i18n/test/translate.test.ts` — no changes required, existing tests remain unaffected

### Critical Files for Implementation

- `/workspace/ui/src/i18n/locales/fr.ts` - New file to create; the complete French translation map
- `/workspace/ui/src/i18n/lib/types.ts` - Add `"fr"` to the `Locale` union type
- `/workspace/ui/src/i18n/lib/registry.ts` - Register the French locale loader and navigator resolution
- `/workspace/src/i18n/registry.test.ts` - Update hardcoded locale list and add French-specific test assertions
- `/workspace/ui/src/i18n/locales/en.ts` - Pattern/source to translate from (read-only reference)