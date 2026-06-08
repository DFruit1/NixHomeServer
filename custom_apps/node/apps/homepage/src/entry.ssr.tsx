import { renderToStream, type RenderToStreamOptions } from '@builder.io/qwik/server';
import Root from './root';

export default function render(options: RenderToStreamOptions) {
  return renderToStream(<Root />, {
    ...options,
    containerTagName: 'html',
    containerAttributes: {
      lang: 'en',
      ...options.containerAttributes,
    },
  });
}
