import { $, component$, useSignal, useVisibleTask$ } from '@builder.io/qwik';
import type { PowerScheduleResponse } from '../shared/types.js';

const hourLabel = (hour: number): string => `${`${hour}`.padStart(2, '0')}:00`;
const hours = Array.from({ length: 24 }, (_, hour) => hour);

export const PowerScheduleCard = component$(() => {
  const schedule = useSignal<PowerScheduleResponse>();
  const error = useSignal('');
  const saved = useSignal('');
  const saving = useSignal(false);
  const enabled = useSignal(true);
  const wakeTime = useSignal('10:30');
  const idleStart = useSignal(22);
  const forcedEnd = useSignal(10);
  const skipToday = useSignal(false);
  const loaded = useSignal(false);

  useVisibleTask$(async () => {
    try {
      const response = await fetch('/api/power-schedule', { headers: { accept: 'application/json' } });
      if (!response.ok) throw new Error((await response.json()).error ?? `HTTP ${response.status}`);
      const next = await response.json() as PowerScheduleResponse;
      schedule.value = next;
      enabled.value = next.current.enabled;
      wakeTime.value = next.current.wakeTime;
      idleStart.value = next.current.idleWindowStartHour;
      forcedEnd.value = next.current.forcedWindowEndHour;
      skipToday.value = next.current.skipDate === new Date().toISOString().slice(0, 10);
      loaded.value = true;
    } catch (caught) {
      error.value = caught instanceof Error ? caught.message : String(caught);
    }
  });

  const save = $(async () => {
    saving.value = true;
    error.value = '';
    saved.value = '';
    try {
      const response = await fetch('/api/power-schedule', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          enabled: enabled.value,
          wakeTime: wakeTime.value,
          idleWindowStartHour: idleStart.value,
          forcedWindowEndHour: forcedEnd.value,
          ...(skipToday.value ? { skipDate: new Date().toISOString().slice(0, 10) } : { skipDate: null }),
        }),
      });
      const body = await response.json() as PowerScheduleResponse & { error?: string };
      if (!response.ok) throw new Error(body.error ?? `HTTP ${response.status}`);
      schedule.value = body;
      saved.value = `Saved ${body.current.updatedAt ? new Date(body.current.updatedAt).toLocaleString() : ''}`.trim();
    } catch (caught) {
      error.value = caught instanceof Error ? caught.message : String(caught);
    } finally {
      saving.value = false;
    }
  });

  const useDefaults = $(() => {
    if (!schedule.value) return;
    enabled.value = schedule.value.defaults.enabled;
    wakeTime.value = schedule.value.defaults.wakeTime;
    idleStart.value = schedule.value.defaults.idleWindowStartHour;
    forcedEnd.value = schedule.value.defaults.forcedWindowEndHour;
  });

  return (
    <section class="canary-panel power-schedule" aria-labelledby="power-schedule-heading">
      <div class="canary-panel__header">
        <div>
          <h2 id="power-schedule-heading">Power schedule</h2>
          <p>Nightly suspend windows and morning wake alarm; changes apply on the next 15-minute check.</p>
        </div>
      </div>
      {schedule.value?.warning && <div class="notice">{schedule.value.warning}</div>}
      {error.value && <p class="notice">{error.value}</p>}
      {loaded && (
        <form class="power-schedule__form" preventdefault:submit onSubmit$={save}>
          <label class="power-schedule__field power-schedule__field--check">
            <input
              type="checkbox"
              checked={enabled.value}
              onChange$={(event) => (enabled.value = (event.target as HTMLInputElement).checked)}
            />
            <span>Nightly suspend enabled</span>
          </label>
          <label class="power-schedule__field power-schedule__field--check">
            <input
              type="checkbox"
              checked={skipToday.value}
              onChange$={(event) => (skipToday.value = (event.target as HTMLInputElement).checked)}
            />
            <span>Skip sleep for today</span>
          </label>
          <label class="power-schedule__field">
            <span>Wake time (power on)</span>
            <input
              type="time"
              required
              value={wakeTime.value}
              onInput$={(event) => (wakeTime.value = (event.target as HTMLInputElement).value)}
            />
          </label>
          <label class="power-schedule__field">
            <span>Evening idle checks start</span>
            <select
              value={`${idleStart.value}`}
              onChange$={(event) => (idleStart.value = Number((event.target as HTMLSelectElement).value))}
            >
              {hours.map((hour) => <option key={hour} value={`${hour}`}>{hourLabel(hour)}</option>)}
            </select>
          </label>
          <label class="power-schedule__field">
            <span>Overnight forced cutoff ends</span>
            <select
              value={`${forcedEnd.value}`}
              onChange$={(event) => (forcedEnd.value = Number((event.target as HTMLSelectElement).value))}
            >
              {hours.map((hour) => <option key={hour} value={`${hour}`}>{hourLabel(hour)}</option>)}
            </select>
          </label>
          <div class="power-schedule__actions">
            <button type="submit" disabled={saving.value}>{saving.value ? 'Saving…' : 'Save schedule'}</button>
            <button type="button" disabled={saving.value} onClick$={useDefaults}>Use Nix defaults</button>
            {saved.value && <span class="power-schedule__saved">{saved.value}</span>}
          </div>
        </form>
      )}
      <p class="power-schedule__notes">
        Sleep checks between the forced cutoff and evening start are skipped. “Skip sleep for today” expires at the
        next calendar date, and a wake during an overnight window holds that window until the next evening.
      </p>
    </section>
  );
});
