import { component$, useSignal, useVisibleTask$ } from '@builder.io/qwik';
import type { MkvProgressResponse } from '../shared/types.js';

const eta = (seconds?: number): string => {
  if (seconds === undefined) return 'Calculating…';
  if (seconds < 60) return 'Less than a minute';
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.ceil((seconds % 3600) / 60);
  return hours > 0 ? `${hours}h ${minutes}m` : `${minutes} min`;
};

export const MkvConversionCard = component$(() => {
  const status = useSignal<MkvProgressResponse>();
  const failed = useSignal(false);

  useVisibleTask$(({ cleanup }) => {
    let cancelled = false;
    const refresh = async () => {
      try {
        const response = await fetch('/api/mkvmaker/progress', { headers: { accept: 'application/json' } });
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        const next = await response.json() as MkvProgressResponse;
        if (!cancelled) {
          status.value = next;
          failed.value = false;
        }
      } catch {
        if (!cancelled) failed.value = true;
      }
    };
    void refresh();
    const timer = window.setInterval(() => void refresh(), 3_000);
    cleanup(() => {
      cancelled = true;
      window.clearInterval(timer);
    });
  });

  const conversions = status.value?.conversions ?? [];
  return (
    <section class="mkv-progress-card detail-block" aria-labelledby="mkv-progress-heading" aria-live="polite">
      <div class="mkv-progress-card__heading">
        <div>
          <h3 id="mkv-progress-heading">DVD conversion progress</h3>
          <p>Movies and episodes being prepared for Jellyfin.</p>
        </div>
        {status.value?.state === 'converting' && <span class="mkv-progress-card__active">Converting</span>}
      </div>
      {!status.value && !failed.value && <p class="mkv-progress-card__empty">Checking for active conversions…</p>}
      {failed.value && <p class="mkv-progress-card__empty">Conversion progress is temporarily unavailable.</p>}
      {status.value && !failed.value && !status.value.enabled && (
        <p class="mkv-progress-card__empty">Automatic DVD conversion is not enabled.</p>
      )}
      {status.value?.enabled && !failed.value && (!status.value.available || status.value.state === 'idle') && (
        <p class="mkv-progress-card__empty">
          {status.value.available ? 'No movies or episodes are being converted right now.' : 'Conversion progress is temporarily unavailable.'}
        </p>
      )}
      {conversions.map((conversion) => {
        const percent = Math.round(conversion.percent * 10) / 10;
        const itemPercent = Math.round(conversion.itemPercent * 10) / 10;
        return (
          <article class="mkv-progress-item" key={`${conversion.title}-${conversion.itemIndex}`}>
            <div class="mkv-progress-item__title">
              <div>
                <strong>{conversion.title}</strong>
                <span>{conversion.mediaKind === 'tv' ? 'TV episode' : 'Movie'} · item {conversion.itemIndex} of {conversion.itemCount}</span>
              </div>
              <strong>{percent.toFixed(1)}%</strong>
            </div>
            <progress max={100} value={percent} aria-label={`${conversion.title} ${percent.toFixed(1)}% converted`}>
              {percent.toFixed(1)}%
            </progress>
            <div class="mkv-progress-item__meta">
              <span>{conversion.itemName} · {itemPercent.toFixed(1)}%</span>
              <span>ETA {eta(conversion.etaSeconds)}{conversion.rateFps ? ` · ${conversion.rateFps.toFixed(1)} fps` : ''}</span>
            </div>
          </article>
        );
      })}
    </section>
  );
});
