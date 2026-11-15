import { $, component$, useContext, useStore, useVisibleTask$ } from '@builder.io/qwik';
import { Link, useLocation } from '@builder.io/qwik-city';
import { HomepageContext } from '../../shared/homepage-context.js';
import { guideHref } from '../../shared/guide-data.js';
import { buildSteps, resolveStepId, stepIds } from './steps.js';

export default component$(() => {
  const homepage = useContext(HomepageContext);
  const location = useLocation();
  const data = homepage.data;
  const username = data?.user.username ?? '{username}';
  const requestedStep = resolveStepId(location.url.searchParams.get('step'));
  const state = useStore<{ open: string; done: string[] }>({ open: requestedStep ?? stepIds[0], done: [] });
  const storageKey = `homepage.gettingStartedDone.${username}`;

  useVisibleTask$(() => {
    // The per-task checklist this page used to keep is no longer read.
    window.localStorage.removeItem(`homepage.gettingStartedChecks.${username}`);
    try {
      const saved = JSON.parse(window.localStorage.getItem(storageKey) ?? '[]') as unknown;
      if (Array.isArray(saved)) {
        state.done = saved.filter((id): id is string => typeof id === 'string' && (stepIds as readonly string[]).includes(id));
      }
    } catch {
      window.localStorage.removeItem(storageKey);
    }
    // A link to a particular step wins; otherwise resume at the first step still to do.
    if (!requestedStep) {
      state.open = stepIds.find((id) => !state.done.includes(id)) ?? '';
    }
  });

  const saveDone = $((done: string[]) => {
    state.done = done;
    try {
      window.localStorage.setItem(storageKey, JSON.stringify(done));
    } catch {
      // Progress still works for this visit when browser storage is unavailable.
    }
  });

  const toggle = $((id: string) => {
    state.open = state.open === id ? '' : id;
  });

  const complete = $(async (id: string, nextId: string) => {
    if (!state.done.includes(id)) {
      await saveDone([...state.done, id]);
    }
    state.open = nextId;
    if (nextId) {
      const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
      window.requestAnimationFrame(() => {
        document.getElementById(`step-${nextId}`)?.scrollIntoView({ block: 'start', behavior: reducedMotion ? 'auto' : 'smooth' });
      });
    }
  });

  const reopen = $(async (id: string) => {
    await saveDone(state.done.filter((doneId) => doneId !== id));
  });

  const steps = buildSteps({
    username,
    kanidmUrl: `https://id.${data?.domain ?? 'example.test'}`,
    serverLanHost: data?.serverLanHost,
    services: (data?.services ?? []).filter((service) => service.enabled),
    folderGuides: data?.folderGuides ?? [],
    sftp: data?.sftp,
  });

  return (
    <section class="doc doc--narrow start">
      <header class="doc-head">
        <h1>Getting started</h1>
        <p class="doc-lead">
          {steps.length} steps to set up your account and devices. Do them in order the first time; step progress is saved only in this browser profile.
        </p>
      </header>

      <ol class="start-steps">
        {steps.map((step, index) => {
          const stepId = step.id;
          const next = steps[index + 1];
          const nextId = next?.id ?? '';
          const open = state.open === stepId;
          const done = state.done.includes(stepId);
          return (
            <li key={stepId} id={`step-${stepId}`} class={{ 'start-step': true, 'is-open': open, 'is-done': done }}>
              <h2 class="start-step__head">
                <button
                  type="button"
                  aria-expanded={open ? 'true' : 'false'}
                  aria-controls={`step-${stepId}-body`}
                  onClick$={() => toggle(stepId)}
                >
                  <span class="start-step__mark" aria-hidden="true">
                    {done ? (
                      <svg viewBox="0 0 24 24" width="16" height="16"><path d="M20 6 9 17l-5-5" /></svg>
                    ) : index + 1}
                  </span>
                  <span class="start-step__title">{step.label}</span>
                  {step.optional && <span class="doc-tag">Optional</span>}
                  {done && <span class="doc-sr">Done</span>}
                  <svg class="start-step__chevron" viewBox="0 0 24 24" width="18" height="18" aria-hidden="true"><path d="m6 9 6 6 6-6" /></svg>
                </button>
              </h2>
              <div class="start-step__body doc-prose" id={`step-${stepId}-body`} hidden={!open}>
                {step.content}
                <div class="start-step__foot">
                  {done ? (
                    <button type="button" class="doc-btn doc-btn--quiet" onClick$={() => reopen(stepId)}>Mark as not done</button>
                  ) : (
                    <button type="button" class="doc-btn doc-btn--primary" onClick$={() => complete(stepId, nextId)}>
                      {next ? `Done, next: ${next.label}` : 'Done'}
                    </button>
                  )}
                </div>
              </div>
            </li>
          );
        })}
      </ol>

      <footer class="start-after doc-prose">
        <h2>After setup</h2>
        <ul class="doc-rows">
          <li>
            <div>
              <strong>Detailed Guide</strong>
              <span>What each app does, where its files go, and what to check when something fails.</span>
            </div>
            <Link class="doc-btn" href="/uploads">Open the guide</Link>
          </li>
          <li>
            <div>
              <strong>Keys &amp; Secrets</strong>
              <span>Passwords and keys for reader apps and devices that cannot use your normal sign-in.</span>
            </div>
            <Link class="doc-btn" href="/keys">Open Keys &amp; Secrets</Link>
          </li>
        </ul>
        <p class="doc-note">
          <strong>Asking for help?</strong> Say which app, when, which network you were on and the exact error. Never include a password, link or code.{' '}
          <Link href={guideHref('help')}>Troubleshooting</Link>
        </p>
      </footer>
    </section>
  );
});
