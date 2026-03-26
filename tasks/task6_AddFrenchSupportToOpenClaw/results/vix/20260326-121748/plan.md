I now have everything needed to produce a precise, complete implementation plan.

---

## Implementation Plan: French (fr) Locale Support

### Overview

Four files need to be modified or created, plus a new git branch must be created. The work follows an exact pattern established by the existing locales. No architectural decisions are needed — the pattern is fully determined.

---

### Step 1: Create the git branch

Before any file changes, create and check out a new branch:

```
git checkout -b feat/french-locale
```

---

### Step 2: Create `/workspace/ui/src/i18n/locales/fr.ts`

This is the largest piece of work. The file must:
- Import `TranslationMap` from `"../lib/types.ts"`
- Export a `const fr: TranslationMap` (simple identifier `fr`, same as `de` and `es` — not an underscore variant)
- Translate every key present in `en.ts` into French
- Include a `languages.fr` key that names French in French (e.g., `"Français"`)

The file must cover all top-level sections from `en.ts`:

`common`, `nav`, `tabs`, `subtitles`, `overview` (all nested subsections: `access`, `snapshot`, `stats`, `notes`, `auth`, `pairing`, `insecure`, `connection`, `cards`, `attention`, `eventLog`, `logTail`, `quickActions`, `palette`), `login`, `chat`, `languages`, `cron` (all nested subsections: `summary`, `jobs`, `runs`, `form`, `jobList`, `jobDetail`, `jobState`, `runEntry`, `errors`).

Notable translation decisions to make (following the style of `es.ts` and `pt-BR.ts`):

- `common.health`: "Santé"
- `common.connect`: "Connecter"
- `common.refresh`: "Actualiser"
- `common.enabled`: "Activé"
- `common.disabled`: "Désactivé"
- `common.version`: "Version"
- `common.docs`: "Docs"
- `common.theme`: "Thème"
- `common.resources`: "Ressources"
- `common.search`: "Rechercher"
- `common.na`: "n/a"
- `nav.settings`: "Paramètres"
- `nav.expand`: "Développer la barre latérale"
- `nav.collapse`: "Réduire la barre latérale"
- `nav.resize`: "Redimensionner la barre latérale"
- `tabs.overview`: "Aperçu"
- `tabs.channels`: "Canaux"
- `tabs.sessions`: "Sessions"
- `tabs.usage`: "Utilisation"
- `tabs.cron`: "Tâches Cron"
- `tabs.skills`: "Compétences"
- `tabs.nodes`: "Nœuds"
- `tabs.config`: "Config"
- `tabs.communications`: "Communications"
- `tabs.appearance`: "Apparence"
- `tabs.automation`: "Automatisation"
- `tabs.infrastructure`: "Infrastructure"
- `tabs.aiAgents`: "IA & Agents"
- `tabs.debug`: "Débogage"
- `tabs.logs`: "Journaux"
- `overview.access.title`: "Accès à la passerelle"
- `overview.access.language`: "Langue"
- `overview.connection.title`: "Comment se connecter"
- `overview.cards.cost`: "Coût"
- `overview.cards.recentSessions`: "Sessions récentes"
- `overview.attention.title`: "Attention"
- `overview.eventLog.title`: "Journal d'événements"
- `overview.logTail.title`: "Journaux de la passerelle"
- `overview.quickActions.newSession`: "Nouvelle session"
- `overview.quickActions.refreshAll`: "Tout actualiser"
- `login.subtitle`: "Tableau de bord de la passerelle"
- `login.passwordPlaceholder`: "facultatif"
- `chat.disconnected`: "Déconnecté de la passerelle."
- `chat.thinkingToggle`: "Basculer la sortie de réflexion/travail de l'assistant"
- `chat.toolCallsToggle`: "Basculer les appels d'outils et les résultats"
- `chat.focusToggle`: "Basculer le mode focus (masquer la barre latérale + l'en-tête)"
- `chat.onboardingDisabled`: "Désactivé pendant la configuration"
- `languages.en`: "Anglais (English)"
- `languages.zhCN`: "Chinois simplifié (简体中文)"
- `languages.zhTW`: "Chinois traditionnel (繁體中文)"
- `languages.ptBR`: "Portugais brésilien (Português)"
- `languages.de`: "Deutsch (Allemand)"
- `languages.es`: "Español (Espagnol)"
- `languages.fr`: "Français"
- All `cron.*` keys translated (tâche = job, exécution = run, planification = schedule, etc.)

The `password` field in `overview.access` should carry the comment `// pragma: allowlist secret` as seen in `es.ts` line 62.

---

### Step 3: Edit `/workspace/ui/src/i18n/lib/types.ts`

Change line 3 from:

```ts
export type Locale = "en" | "zh-CN" | "zh-TW" | "pt-BR" | "de" | "es";
```

to:

```ts
export type Locale = "en" | "zh-CN" | "zh-TW" | "pt-BR" | "de" | "es" | "fr";
```

This is a single-line, single-character addition.

---

### Step 4: Edit `/workspace/ui/src/i18n/lib/registry.ts`

Three targeted additions are needed:

**4a. Add `"fr"` to `LAZY_LOCALES` (line 13):**

```ts
const LAZY_LOCALES: readonly LazyLocale[] = ["zh-CN", "zh-TW", "pt-BR", "de", "es", "fr"];
```

**4b. Add `fr` entry to `LAZY_LOCALE_REGISTRY` (after `es` block, before the closing `}`  of the object, lines 28–36):**

```ts
  fr: {
    exportName: "fr",
    loader: () => import("../locales/fr.ts"),
  },
```

**4c. Add French resolution to `resolveNavigatorLocale` (after the `es` branch, before `return DEFAULT_LOCALE`, lines 58–61):**

```ts
  if (navLang.startsWith("fr")) {
    return "fr";
  }
```

---

### Step 5: Edit `/workspace/src/i18n/registry.test.ts`

**5a. Update the `SUPPORTED_LOCALES` assertion (line 23):**

```ts
expect(SUPPORTED_LOCALES).toEqual(["en", "zh-CN", "zh-TW", "pt-BR", "de", "es", "fr"]);
```

**5b. Add a `resolveNavigatorLocale` test case for French (within the existing `it("resolves browser locale fallbacks"` block, after line 33):**

```ts
    expect(resolveNavigatorLocale("fr-FR")).toBe("fr");
    expect(resolveNavigatorLocale("fr-CA")).toBe("fr");
```

**5c. Add a `loadLazyLocaleTranslation` assertion for French (within the existing `it("loads lazy locale translations"` block):**

Load `fr` and assert a known key:

```ts
    const fr = await loadLazyLocaleTranslation("fr");
    expect(getNestedTranslation(fr, "common", "health")).toBe("Santé");
```

This also requires adding `"fr"` to the list of loaded translations in the test's `loadLazyLocaleTranslation` calls. The import of `fr` does not need to be added to the test file's top-level imports (the test uses `loadLazyLocaleTranslation` dynamically, not a static import).

Also update the `languages.fr` assertion counterpart: the `languages` section in other locales names the French locale. All existing locale files (`de.ts`, `es.ts`, `pt-BR.ts`, `zh-CN.ts`, `zh-TW.ts`) will not be changed — they don't need a `languages.fr` key for tests to pass; the fallback to English handles missing keys automatically.

---

### Sequencing and Dependencies

1. Create branch (no file deps)
2. Create `fr.ts` (depends only on `types.ts` already being valid — which it is before we edit it, since `fr` is not yet in the type; however the file itself will compile after `types.ts` is updated)
3. Edit `types.ts` — makes `"fr"` a valid `Locale` value; this must happen before or together with the registry edits
4. Edit `registry.ts` — depends on `"fr"` being a valid `Locale` (step 3) and `fr.ts` existing (step 2)
5. Edit `registry.test.ts` — depends on steps 3 and 4 being complete so that the assertions match actual runtime values

In practice for implementation, the order should be: `types.ts` edit → `fr.ts` creation → `registry.ts` edits → `registry.test.ts` edits → commit.

---

### Potential Challenges

- TypeScript's `Record<LazyLocale, LazyLocaleRegistration>` will produce a compile error if `"fr"` is in `LAZY_LOCALES` but not in `LAZY_LOCALE_REGISTRY`, or vice versa. Both must be updated atomically.
- The `SUPPORTED_LOCALES` test assertion is an exact `toEqual`, so the order matters. `"fr"` must be appended at the end of the array, matching the order in `LAZY_LOCALES`.
- The `fr.ts` export name must be `fr` (not `fr_FR` or any other variant), because `exportName: "fr"` in the registry will look up `module["fr"]`.

---

### Critical Files for Implementation

- `/workspace/ui/src/i18n/locales/fr.ts` - New file to create; the complete French translation map
- `/workspace/ui/src/i18n/lib/types.ts` - Add `"fr"` to the `Locale` union type
- `/workspace/ui/src/i18n/lib/registry.ts` - Register `fr` in `LAZY_LOCALES`, `LAZY_LOCALE_REGISTRY`, and `resolveNavigatorLocale`
- `/workspace/src/i18n/registry.test.ts` - Update `SUPPORTED_LOCALES` assertion and add French locale test cases
- `/workspace/ui/src/i18n/locales/en.ts` - Reference source for all translation keys (read-only reference)