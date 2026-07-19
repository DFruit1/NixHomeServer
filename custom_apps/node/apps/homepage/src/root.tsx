import { component$ } from '@builder.io/qwik';
import { QwikCityProvider, RouterOutlet, ServiceWorkerRegister, useDocumentHead } from '@builder.io/qwik-city';
import { fallbackBrandName } from './shared/branding.js';
import './global.css';

export default component$(() => (
  <QwikCityProvider viewTransition={false}>
    <head>
      <meta charSet="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <RouterHead />
    </head>
    <body>
      <RouterOutlet />
      <ServiceWorkerRegister />
    </body>
  </QwikCityProvider>
));

export const RouterHead = component$(() => {
  const head = useDocumentHead();

  return (
    <>
      <title>{head.title || fallbackBrandName}</title>
      {head.meta.map((meta) => (
        <meta key={meta.key} {...meta} />
      ))}
      {head.links.map((link) => (
        <link key={link.key} {...link} />
      ))}
      {head.styles.map((style) => (
        <style key={style.key} dangerouslySetInnerHTML={style.style} />
      ))}
    </>
  );
});
