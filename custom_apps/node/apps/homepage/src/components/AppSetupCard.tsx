import { component$ } from '@builder.io/qwik';
import { Link } from '@builder.io/qwik-city';

export const AppSetupCard = component$(
  ({
    title,
    platform,
    url,
    detail,
    steps,
  }: {
    title: string;
    platform: string;
    url: string;
    detail: string;
    steps: string[];
  }) => (
    <article class="app-setup-card">
      <div>
        <h3>{title}</h3>
        <span>{platform}</span>
      </div>
      <p>{detail}</p>
      <ol class="steps">
        {steps.map((step) => (
          <li key={step}>{step}</li>
        ))}
      </ol>
      {url.startsWith('/') ? (
        <Link class="open-link" href={url}>
          Open setup
        </Link>
      ) : (
        <a class="open-link" href={url}>
          Open setup
        </a>
      )}
    </article>
  ),
);
