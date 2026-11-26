// Product identity. Protocol names and provider-specific identifiers remain stable.
export const productName = "Notchbee";
export const engineName = `${productName.toLowerCase()}-engine`;
export const engineEnv = (key: string) => `${productName.toUpperCase()}_ENGINE_${key}`;
export const engineUserAgent = `${productName}-Engine`;
export const remoteAccessName = "Remote access";
