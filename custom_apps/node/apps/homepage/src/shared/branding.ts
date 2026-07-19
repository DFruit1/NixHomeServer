export const fallbackBrandName = 'Home Server';

export const brandedPageTitle = (brandName: string | undefined, page?: string): string => {
  const brand = brandName?.trim() || fallbackBrandName;
  return page ? `${page} | ${brand}` : brand;
};
