## Implementation Plan: French (fr) Language Support

### Overview

The i18n system lives in `/workspace/ui/src/i18n/`. Adding French requires changes to 5 existing files and creation of 1 new file. The system uses lazy-loading: English is the default (always loaded), all other locales are loaded on demand via dynamic `import()`.

### Architecture Understanding

The locale pipeline is:
1. `types.ts` declares the `Locale` union type
2. `registry.ts` lists supported locales, their lazy loaders, and the navigator-language resolver
3. A new `locales/fr.ts` file exports the `fr` `TranslationMap`
4. Every existing locale's `languages` sub-object needs a `fr` entry so the language picker shows "French" in each language
5. `registry.test.ts` hard-codes the `SUPPORTED_LOCALES` array and the `resolveNavigatorLocale` cases — both must be updated

### Step-by-Step Implementation

**Step 1: Create `/workspace/ui/src/i18n/locales/fr.ts`**

This is the main translation file. It must export a `const fr: TranslationMap`. The content model to follow is `es.ts` (the most complete non-CJK locale, with full `cron` section). Every key present in `en.ts` should be translated. Key structural notes:
- All top-level sections: `common`, `nav`, `tabs`, `subtitles`, `overview`, `login`, `chat`, `languages`, `cron`
- `overview` contains: `access`, `snapshot`, `stats`, `notes`, `auth`, `pairing`, `insecure`, `connection`, `cards`, `attention`, `eventLog`, `logTail`, `quickActions`, `palette`
- `cron` contains: `summary`, `jobs`, `runs`, `form`, `jobList`, `jobDetail`, `jobState`, `runEntry`, `errors`
- The `languages` sub-object must list all 7 locales including `fr` itself: `en`, `zhCN`, `zhTW`, `ptBR`, `de`, `es`, `fr`

Representative French translations for the full key set (following the pattern of `es.ts` as a guide):

```
common: { version:"Version", health:"État", ok:"OK", online:"En ligne", offline:"Hors ligne",
  connect:"Connecter", refresh:"Actualiser", enabled:"Activé", disabled:"Désactivé",
  na:"n/a", docs:"Docs", resources:"Ressources", search:"Rechercher" }

nav: { chat:"Chat", control:"Contrôle", agent:"Agent", settings:"Paramètres",
  expand:"Agrandir la barre latérale", collapse:"Réduire la barre latérale",
  resize:"Redimensionner la barre latérale" }

tabs: { agents:"Agents", overview:"Vue d'ensemble", channels:"Canaux",
  instances:"Instances", sessions:"Sessions", usage:"Utilisation",
  cron:"Tâches Cron", skills:"Compétences", nodes:"Nœuds", chat:"Chat",
  config:"Config", communications:"Communications", appearance:"Apparence",
  automation:"Automatisation", infrastructure:"Infrastructure",
  aiAgents:"IA & Agents", debug:"Débogage", logs:"Journaux" }
```

**Step 2: Update `/workspace/ui/src/i18n/lib/types.ts`**

Change the `Locale` union type from:
```
export type Locale="en"|"zh-CN"|"zh-TW"|"pt-BR"|"de"|"es";
```
to:
```
export type Locale="en"|"zh-CN"|"zh-TW"|"pt-BR"|"de"|"es"|"fr";
```

**Step 3: Update `/workspace/ui/src/i18n/lib/registry.ts`**

Three changes in this file:

a) Add `"fr"` to `LAZY_LOCALES`:
```
const LAZY_LOCALES:readonly LazyLocale[]=["zh-CN","zh-TW","pt-BR","de","es","fr"];
```

b) Add the French entry to `LAZY_LOCALE_REGISTRY`:
```
fr:{exportName:"fr",loader:()=>import("../locales/fr.ts"),},
```

c) Add French to `resolveNavigatorLocale` — French browser locales start with `"fr"`:
```
if(navLang.startsWith("fr")){return"fr";}
```
This should be inserted before the final `return DEFAULT_LOCALE` fallback, following the pattern of the existing `de` and `es` cases.

**Step 4: Update `/workspace/ui/src/i18n/locales/en.ts`**

Add `fr` to the `languages` sub-object so the language picker shows the French option when the UI is in English:
```
fr:"French",
```
The full entry in context: add after `es:"Español (Spanish)",` as `fr:"Français (French)",`

**Step 5: Update all other locale files to add `fr` to their `languages` sub-object**

Each existing locale must name French in its own language:

- `/workspace/ui/src/i18n/locales/de.ts`: add `fr:"Französisch (Français)",`
- `/workspace/ui/src/i18n/locales/es.ts`: add `fr:"Francés (Français)",`
- `/workspace/ui/src/i18n/locales/pt-BR.ts`: add `fr:"Français (Francês)",`
- `/workspace/ui/src/i18n/locales/zh-CN.ts`: add `fr:"Français (法语)",`
- `/workspace/ui/src/i18n/locales/zh-TW.ts`: add `fr:"Français (法語)",`

And in the new `fr.ts` itself, the `languages` block names French as `fr:"Français"` and the other languages in French:
```
languages: {
  en:"Anglais (English)", zhCN:"简体中文 (Chinois simplifié)",
  zhTW:"繁體中文 (Chinois traditionnel)", ptBR:"Português (Portugais brésilien)",
  de:"Deutsch (Allemand)", es:"Español (Espagnol)", fr:"Français"
}
```

**Step 6: Update `/workspace/src/i18n/registry.test.ts`**

Two changes:

a) The `"lists supported locales"` test hard-codes the array:
```
expect(SUPPORTED_LOCALES).toEqual(["en","zh-CN","zh-TW","pt-BR","de","es"]);
```
Must become:
```
expect(SUPPORTED_LOCALES).toEqual(["en","zh-CN","zh-TW","pt-BR","de","es","fr"]);
```

b) Add a `resolveNavigatorLocale` case for French:
```
expect(resolveNavigatorLocale("fr-FR")).toBe("fr");
expect(resolveNavigatorLocale("fr-CA")).toBe("fr");
```

c) Add a `loadLazyLocaleTranslation` assertion for `fr`:
```
const fr=await loadLazyLocaleTranslation("fr");
expect(getNestedTranslation(fr,"common","health")).toBe("État");
expect(getNestedTranslation(fr,"languages","fr")).toBe("Français");
```

**Step 7: Create a PR-ready git branch**

After all file changes are complete:
```
git checkout -b feat/i18n-french-support
git add ui/src/i18n/locales/fr.ts \
        ui/src/i18n/lib/types.ts \
        ui/src/i18n/lib/registry.ts \
        ui/src/i18n/locales/en.ts \
        ui/src/i18n/locales/de.ts \
        ui/src/i18n/locales/es.ts \
        ui/src/i18n/locales/pt-BR.ts \
        ui/src/i18n/locales/zh-CN.ts \
        ui/src/i18n/locales/zh-TW.ts \
        src/i18n/registry.test.ts
git commit -m "feat(i18n): add French (fr) locale support

Adds complete French translations for all UI keys, registers fr
in the locale registry with lazy loading, updates the Locale type,
and extends all existing locale language-picker entries.

Closes #3460"
```

### Sequencing Rationale

The order matters for TypeScript correctness:
1. `types.ts` first — adding `"fr"` to `Locale` unblocks the registry and locale file from type errors
2. `fr.ts` second — must exist before `registry.ts` references it via `import()`
3. `registry.ts` third — wires up the new locale
4. Existing locale files fourth — purely additive `languages` entries, no structural risk
5. Test file last — update to match the new expected state

### Critical Files for Implementation

- `/workspace/ui/src/i18n/lib/types.ts` - Locale union type that must include "fr" to typecheck
- `/workspace/ui/src/i18n/lib/registry.ts` - Core wiring: LAZY_LOCALES array, LAZY_LOCALE_REGISTRY map, and resolveNavigatorLocale function all need fr entries
- `/workspace/ui/src/i18n/locales/en.ts` - Pattern/master key reference and needs fr added to its languages block
- `/workspace/ui/src/i18n/locales/es.ts` - Most complete non-CJK locale to use as the structural template for fr.ts
- `/workspace/src/i18n/registry.test.ts` - Test that hard-codes SUPPORTED_LOCALES and resolver cases, must be updated to include fr