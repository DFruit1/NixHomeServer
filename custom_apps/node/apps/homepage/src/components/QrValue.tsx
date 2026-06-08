import { component$, useSignal, useVisibleTask$ } from '@builder.io/qwik';
import QRCode from 'qrcode';

export const QrValue = component$(({ label, value }: { label: string; value: string }) => {
  const qrDataUrl = useSignal('');

  useVisibleTask$(async ({ track }) => {
    const text = track(() => value);
    qrDataUrl.value = await QRCode.toDataURL(text, {
      errorCorrectionLevel: 'M',
      margin: 1,
      width: 164,
    });
  });

  return (
    <div class="qr-card">
      <h4>{label}</h4>
      {qrDataUrl.value ? <img src={qrDataUrl.value} alt={`${label} QR code`} /> : <div class="qr-placeholder" aria-hidden="true" />}
      <code>{value}</code>
    </div>
  );
});
