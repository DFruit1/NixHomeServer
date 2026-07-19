{ lib }:

let
  validOctetText = value:
    builtins.isString value
    && builtins.match "(0|[1-9][0-9]{0,2})" value != null;
  octetValue = value: builtins.fromJSON value;
  pow2 = exponent:
    builtins.foldl' (value: _: value * 2) 1 (lib.genList (index: index) exponent);
in
rec {
  validIPv4 = value:
    let
      octets = if builtins.isString value then lib.splitString "." value else [ ];
    in
    builtins.length octets == 4
    && builtins.all validOctetText octets
    && builtins.all (octet: octetValue octet <= 255) octets;

  validIPv4Cidr = value:
    let
      parts = if builtins.isString value then lib.splitString "/" value else [ ];
      addressText = if builtins.length parts == 2 then builtins.elemAt parts 0 else "";
      prefixText = if builtins.length parts == 2 then builtins.elemAt parts 1 else "";
      syntaxValid =
        builtins.length parts == 2
        && validIPv4 addressText
        && builtins.match "(0|[1-9]|[12][0-9]|3[0-2])" prefixText != null;
    in
    syntaxValid
    && (
      let
        prefixLength = builtins.fromJSON prefixText;
        blockSize = pow2 (32 - prefixLength);
        address = ipv4ToInt addressText;
      in
      builtins.div address blockSize * blockSize == address
    );

  ipv4ToInt = value:
    let
      octets = map octetValue (lib.splitString "." value);
    in
    builtins.foldl' (total: octet: total * 256 + octet) 0 octets;

  sameUsableSubnet = address: gateway: prefixLength:
    let
      blockSize = if prefixLength >= 0 && prefixLength <= 32 then pow2 (32 - prefixLength) else 0;
      addressInt = if validIPv4 address then ipv4ToInt address else 0;
      gatewayInt = if validIPv4 gateway then ipv4ToInt gateway else 0;
      usable = value: value - (builtins.div value blockSize) * blockSize;
    in
    validIPv4 address
    && validIPv4 gateway
    && prefixLength >= 1
    && prefixLength <= 30
    && builtins.div addressInt blockSize == builtins.div gatewayInt blockSize
    && usable addressInt != 0
    && usable addressInt != blockSize - 1
    && usable gatewayInt != 0
    && usable gatewayInt != blockSize - 1;

  cidrContains = address: cidr:
    let
      parts = if validIPv4Cidr cidr then lib.splitString "/" cidr else [ "0.0.0.0" "0" ];
      network = builtins.elemAt parts 0;
      prefixLength = builtins.fromJSON (builtins.elemAt parts 1);
      blockSize = pow2 (32 - prefixLength);
    in
    validIPv4 address
    && validIPv4Cidr cidr
    && builtins.div (ipv4ToInt address) blockSize == builtins.div (ipv4ToInt network) blockSize;
}
