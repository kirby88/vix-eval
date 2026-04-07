## Implementation Plan: French (fr) Language Support

### Overview

The codebase has a well-structured i18n system with lazy-loaded locale files. Adding French requires changes to 5 files in a specific dependency order, plus one new file to create.

---

### Step 1: Create `/workspace/ui/src/i18n/locales/fr.ts`

This is the main translation file. It must:
- Import `TranslationMap` from `"../lib/types.ts"`
- Export a named const `fr` of type `TranslationMap`
- Use `es.ts` as the primary template (it has the most complete coverage at ~307 lines vs en's ~350)
- Cover all top-level sections present in `en.ts`: `common`, `nav`, `tabs`, `subtitles`, `overview`, `login`, `chat`, `languages`, `cron`

Key French translations for each section (following the same structural pattern as `es.ts`):

**`common`**: version, health ("Santé"), ok, online ("En ligne"), offline ("Hors ligne"), connect ("Connecter"), refresh ("Actualiser"), enabled ("Activé"), disabled ("Désactivé"), na ("n/d"), docs, resources ("Ressources"), search ("Rechercher"), theme ("Thème")

**`nav`**: chat, control ("Contrôle"), agent ("Agent"), settings ("Paramètres"), expand ("Développer la barre latérale"), collapse ("Réduire la barre latérale"), resize ("Redimensionner la barre latérale")

**`tabs`**: agents ("Agents"), overview ("Vue d'ensemble"), channels ("Canaux"), instances ("Instances"), sessions ("Sessions"), usage ("Utilisation"), cron ("Tâches Cron"), skills ("Compétences"), nodes ("Nœuds"), chat, config ("Config"), communications ("Communications"), appearance ("Apparence"), automation ("Automatisation"), infrastructure ("Infrastructure"), aiAgents ("IA et Agents"), debug ("Débogage"), logs ("Journaux")

**`subtitles`**: (short descriptions matching the en.ts pattern)

**`overview`**: Full nested object covering access, snapshot, stats, notes, auth, pairing, insecure, connection, cards, attention, eventLog, logTail, quickActions, palette subsections

**`login`**: subtitle ("Tableau de bord de la passerelle"), passwordPlaceholder ("optionnel")

**`chat`**: disconnected, refreshTitle, thinkingToggle, toolCallsToggle, focusToggle, hideCronSessions, showCronSessions, showCronSessionsHidden, onboardingDisabled

**`languages`**: All existing locales listed in their French names:
- en: "Anglais (English)"
- zhCN: "Chinois simplifié (简体中文)"
- zhTW: "Chinois traditionnel (繁體中文)"
- ptBR: "Portugais brésilien (Português)"
- de: "Allemand (Deutsch)"
- es: "Espagnol (Español)"
- fr: "Français"

**`cron`**: Full nested object covering summary, jobs, runs, form, jobList, jobDetail, jobState, runEntry, errors subsections -- following `es.ts` as the template (it has the complete cron section)

---

### Step 2: Update `/workspace/ui/src/i18n/lib/types.ts`

Add `"fr"` to the `Locale` union type:

Current: `export type Locale = "en" | "zh-CN" | "zh-TW" | "pt-BR" | "de" | "es";`
Updated: `export type Locale = "en" | "zh-CN" | "zh-TW" | "pt-BR" | "de" | "es" | "fr";`

---

### Step 3: Update `/workspace/ui/src/i18n/lib/registry.ts`

Three additions needed:

1. Add `"fr"` to the `LAZY_LOCALES` array:
   - Current: `["zh-CN","zh-TW","pt-BR","de","es"]`
   - Updated: `["zh-CN","zh-TW","pt-BR","de","es","fr"]`

2. Add an entry to `LAZY_LOCALE_REGISTRY`:
   ```
   fr: {
     exportName: "fr",
     loader: () => import("../locales/fr.ts"),
   },
   ```

3. Add a French branch to `resolveNavigatorLocale`:
   ```
   if (navLang.startsWith("fr")) {
     return "fr";
   }
   ```
   Insert this before the final `return DEFAULT_LOCALE` fallback, following the same pattern as the other branches.

---

### Step 4: Update existing locale files to include French in their `languages` section

Each existing locale file must add a `fr` key to its `languages` object. The value should name French in that language:

- `/workspace/ui/src/i18n/locales/de.ts`: add `fr: "Französisch (Français)"`
- `/workspace/ui/src/i18n/locales/es.ts`: add `fr: "Francés (Français)"`
- `/workspace/ui/src/i18n/locales/pt-BR.ts`: add `fr: "Francês (Français)"`
- `/workspace/ui/src/i18n/locales/zh-CN.ts`: add `fr: "Français (法语)"`
- `/workspace/ui/src/i18n/locales/zh-TW.ts`: add `fr: "Français (法語)"`
- `/workspace/ui/src/i18n/locales/en.ts`: add `fr: "Français (French)"`

Note: `en.ts` does not have a `languages` section in the current file -- the fallback mechanism means French users without a `languages.fr` key in English would fall back to the key path. However, looking at `en.ts` more carefully, it does have a `languages` section. Add `fr: "Français (French)"` there.

---

### Step 5: Update `/workspace/src/i18n/registry.test.ts`

The test at line 23 hardcodes the supported locales array:
```
expect(SUPPORTED_LOCALES).toEqual(["en", "zh-CN", "zh-TW", "pt-BR", "de", "es"]);
```
This must be updated to:
```
expect(SUPPORTED_LOCALES).toEqual(["en", "zh-CN", "zh-TW", "pt-BR", "de", "es", "fr"]);
```

The test at line 28-33 (`resolves browser locale fallbacks`) must also have a new assertion added:
```
expect(resolveNavigatorLocale("fr-FR")).toBe("fr");
expect(resolveNavigatorLocale("fr-CA")).toBe("fr");
```

The test `loads lazy locale translations from the registry` should have a new assertion added to verify the French locale loads correctly:
```
const fr = await loadLazyLocaleTranslation("fr");
expect(getNestedTranslation(fr, "common", "health")).toBe("Santé");
```

---

### Step 6: Create a PR-ready Git branch

After all file changes are made:
1. Create a new branch: `git checkout -b feat/french-locale`
2. Stage all changed files: `git add` the 8 affected files
3. Commit: `git commit -m "feat(i18n): add French (fr) locale support"`

---

### Dependency Order

The files must be worked on in this sequence to avoid TypeScript type errors during editing:

1. `fr.ts` (new file) -- can be written first since it only depends on `types.ts` which already exists
2. `types.ts` -- add `"fr"` to the union
3. `registry.ts` -- depends on the updated `types.ts`
4. `en.ts`, `de.ts`, `es.ts`, `pt-BR.ts`, `zh-CN.ts`, `zh-TW.ts` -- add `fr` key to each `languages` object (order does not matter among these)
5. `registry.test.ts` -- update assertions last

---

### Critical Files for Implementation

- `/workspace/ui/src/i18n/locales/fr.ts` - New file to create; the complete French translation map
- `/workspace/ui/src/i18n/lib/types.ts` - Add `"fr"` to the `Locale` union type
- `/workspace/ui/src/i18n/lib/registry.ts` - Register the new locale, add lazy loader, add navigator resolution
- `/workspace/src/i18n/registry.test.ts` - Update test assertions so existing tests pass with the new locale
- `/workspace/ui/src/i18n/locales/en.ts` - Pattern to follow; also needs `fr` added to its `languages` section