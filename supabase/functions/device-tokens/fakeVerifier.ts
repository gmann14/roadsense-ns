// B160 ships with attestation verification STUBBED, not implemented. Real
// verifiers land in B161 (App Attest, iOS) and B163 (Play Integrity,
// Android) -- see docs/implementation/17-device-attestation-and-trust.md.
//
// This fake accepts any well-formed request for a supported platform and
// mints an 'unverified'-tier token. It exists so the B160 endpoints are
// exercisable end to end (acceptance criteria: "challenge -> issue -> rotate
// round-trip works end to end against local Postgres with a fake verifier")
// without pretending to check anything cryptographic. It intentionally:
//   * never returns 'attested' or 'established' -- only a real verifier may
//     grant those tiers, so nothing can accidentally ship to production
//     believing an unverified device passed hardware attestation.
//   * accepts the exact same VerifyAttestation interface B161/B163 must
//     implement, so swapping this out later is a one-line change in
//     server.ts, not a handler/contract change.
//
// DO NOT wire this into a production ATTESTATION_MODE=enforce deployment as
// the real verifier -- it is a development/test convenience only. The
// `ATTESTATION_MODE` env var described in doc 17 governs enforcement, not
// this file; this file is the B160-era placeholder for `verifyAttestation`
// until B161/B163 replace it in server.ts.

import type { AttestationVerification, VerifyAttestation } from "./handler.ts";
import { SUPPORTED_PLATFORMS } from "./handler.ts";

export function createFakeVerifyAttestation(): VerifyAttestation {
    return async (platform: string, params: { keyId: string; attestationObject: string; challenge: string }): Promise<AttestationVerification> => {
        if (!SUPPORTED_PLATFORMS.has(platform)) {
            return { ok: false, reason: "unsupported_platform" };
        }
        if (params.keyId.trim().length === 0 || params.attestationObject.trim().length === 0) {
            return { ok: false, reason: "malformed_attestation" };
        }

        // The handler already restricts key_id to base64/base64url, but the
        // verifier contract says "don't throw for expected failures", so a
        // value btoa() can't encode is a verification failure, not a 503.
        let publicKey: string;
        try {
            publicKey = btoa(`fake-public-key:${params.keyId}`);
        } catch {
            return { ok: false, reason: "malformed_key_id" };
        }

        return {
            ok: true,
            publicKey,
            signCount: 0,
            trustTier: "unverified",
        };
    };
}
