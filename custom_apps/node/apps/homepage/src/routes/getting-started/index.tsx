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
  const state = useStore<{ open: string; done: string[]; focus: string }>({ open: requestedStep ?? stepIds[0], done: [], focus: '' });
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

  const advance = $((id: string, nextId: string) => {
    state.open = nextId;
    // The button that was just clicked disappears with the step body, so hand
    // focus to the step that opens now (or to this step's own toggle after the
    // last one) before the list scrolls there.
    state.focus = nextId || id;
  });

  useVisibleTask$(({ track }) => {
    const target = track(() => state.focus);
    if (!target) {
      return;
    }
    const toggle = document.getElementById(`step-${target}-toggle`) as HTMLButtonElement | null;
    if (!toggle) {
      return;
    }
    toggle.focus({ preventScroll: true });
    document.getElementById(`step-${target}`)?.scrollIntoView({
      block: 'start',
      behavior: window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth',
    });
    state.focus = '';
  });

  const complete = $(async (id: string, nextId: string) => {
    if (!state.done.includes(id)) {
      await saveDone([...state.done, id]);
    }
    await advance(id, nextId);
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
          {steps.length} steps to set up your account and devices. Progress stays in this browser.
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
                  id={`step-${stepId}-toggle`}
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
                <div class="start-step__foot doc-actions">
                  {done ? (
                    <button type="button" class="doc-btn doc-btn--quiet" onClick$={() => reopen(stepId)}>Mark as not done</button>
                  ) : (
                    <button type="button" class="doc-btn doc-btn--primary" onClick$={() => complete(stepId, nextId)}>
                      {next ? 'Done & continue' : 'Done'}
                    </button>
                  )}
                  {step.optional && !done && (
                    <button type="button" class="doc-btn doc-btn--quiet" onClick$={() => advance(stepId, nextId)}>
                      Skip for now
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
              <span>App guides, file locations and troubleshooting.</span>
            </div>
            <Link class="doc-btn" href="/uploads">Open the guide</Link>
          </li>
          <li>
            <div>
              <strong>Keys &amp; Secrets</strong>
              <span>App passwords and device keys.</span>
            </div>
            <Link class="doc-btn" href="/keys">Open Keys &amp; Secrets</Link>
          </li>
        </ul>
        <p class="doc-note">
          Need help? <Link href={guideHref('help')}>Troubleshooting and contacting an admin</Link>.
        </p>
      </footer>
    </section>
  );
});
