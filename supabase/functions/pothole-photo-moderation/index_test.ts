import { assertEquals, assertObjectMatch } from "jsr:@std/assert";
import {
    createPotholePhotoModerationHandler,
    validatePotholePhotoModerationPayload,
} from "./handler.ts";

Deno.test("validatePotholePhotoModerationPayload rejects malformed payloads", () => {
    const result = validatePotholePhotoModerationPayload({
        report_id: "bad",
        decision: "ship-it",
        reviewed_by: "",
    });

    assertEquals(result.ok, false);
    if (!result.ok) {
        assertObjectMatch(result.fieldErrors, {
            report_id: "must be a UUID string",
            decision: "must be approve or reject",
            reviewed_by: "must be a non-empty string",
        });
    }
});

Deno.test("pothole photo moderation handler requires internal auth", async () => {
    const handler = createPotholePhotoModerationHandler({
        authorize: () => false,
        getPhoto: async () => null,
        moveObject: async () => undefined,
        deleteObject: async () => undefined,
        approvePhoto: async () => ({
            report_id: "00000000-0000-4000-8000-000000002101",
            pothole_report_id: "00000000-0000-4000-8000-000000002201",
            status: "approved",
            storage_object_path: "published/00000000-0000-4000-8000-000000002101.jpg",
        }),
        rejectPhoto: async () => ({
            report_id: "00000000-0000-4000-8000-000000002101",
            status: "rejected",
            storage_object_path: "pending/00000000-0000-4000-8000-000000002101.jpg",
        }),
    });

    const response = await handler(new Request("http://localhost/functions/v1/pothole-photo-moderation", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
            report_id: "00000000-0000-4000-8000-000000002101",
            decision: "approve",
            reviewed_by: "mod-1",
        }),
    }));

    assertEquals(response.status, 401);
});

Deno.test("pothole photo moderation handler approves pending photos and moves storage", async () => {
    const moves: Array<[string, string]> = [];
    const approvals: Array<Record<string, string>> = [];
    const handler = createPotholePhotoModerationHandler({
        authorize: () => true,
        getPhoto: async () => ({
            report_id: "00000000-0000-4000-8000-000000002101",
            status: "pending_moderation",
            storage_object_path: "pending/00000000-0000-4000-8000-000000002101.jpg",
        }),
        moveObject: async (fromPath, toPath) => {
            moves.push([fromPath, toPath]);
        },
        deleteObject: async () => undefined,
        approvePhoto: async ({ reportID, reviewedBy, storageObjectPath }) => {
            approvals.push({
                reportID,
                reviewedBy,
                storageObjectPath,
            });
            return {
                report_id: reportID,
                pothole_report_id: "00000000-0000-4000-8000-000000002201",
                status: "approved",
                storage_object_path: storageObjectPath,
            };
        },
        rejectPhoto: async () => ({
            report_id: "00000000-0000-4000-8000-000000002101",
            status: "rejected",
            storage_object_path: "pending/00000000-0000-4000-8000-000000002101.jpg",
        }),
    });

    const response = await handler(new Request("http://localhost/functions/v1/pothole-photo-moderation", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
            report_id: "00000000-0000-4000-8000-000000002101",
            decision: "approve",
            reviewed_by: "mod-1",
        }),
    }));

    assertEquals(response.status, 200);
    assertEquals(moves, [[
        "pending/00000000-0000-4000-8000-000000002101.jpg",
        "published/00000000-0000-4000-8000-000000002101.jpg",
    ]]);
    assertEquals(approvals.length, 1);
    assertEquals(approvals[0].storageObjectPath, "published/00000000-0000-4000-8000-000000002101.jpg");
    assertObjectMatch(await response.json(), {
        report_id: "00000000-0000-4000-8000-000000002101",
        status: "approved",
    });
});

Deno.test("pothole photo moderation handler rejects pending photos and deletes storage", async () => {
    const events: string[] = [];
    const handler = createPotholePhotoModerationHandler({
        authorize: () => true,
        getPhoto: async () => ({
            report_id: "00000000-0000-4000-8000-000000002103",
            status: "pending_moderation",
            storage_object_path: "pending/00000000-0000-4000-8000-000000002103.jpg",
        }),
        moveObject: async () => undefined,
        deleteObject: async (path) => {
            events.push(`delete:${path}`);
        },
        approvePhoto: async () => ({
            report_id: "00000000-0000-4000-8000-000000002103",
            status: "approved",
            storage_object_path: "published/00000000-0000-4000-8000-000000002103.jpg",
        }),
        rejectPhoto: async ({ reportID, reviewedBy, rejectionReason }) => {
            events.push(`reject:${reportID}`);
            assertEquals(reviewedBy, "mod-3");
            assertEquals(rejectionReason, "contains a plate");
            return {
                report_id: reportID,
                status: "rejected",
                storage_object_path: "pending/00000000-0000-4000-8000-000000002103.jpg",
            };
        },
    });

    const response = await handler(new Request("http://localhost/functions/v1/pothole-photo-moderation", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
            report_id: "00000000-0000-4000-8000-000000002103",
            decision: "reject",
            reviewed_by: "mod-3",
            rejection_reason: "contains a plate",
        }),
    }));

    assertEquals(response.status, 200);
    assertEquals(events, [
        "reject:00000000-0000-4000-8000-000000002103",
        "delete:pending/00000000-0000-4000-8000-000000002103.jpg",
    ]);
    assertEquals((await response.json()).status, "rejected");
});

Deno.test("pothole photo moderation handler rolls storage move back when approval RPC fails", async () => {
    const moves: Array<[string, string]> = [];
    const handler = createPotholePhotoModerationHandler({
        authorize: () => true,
        getPhoto: async () => ({
            report_id: "00000000-0000-4000-8000-000000002104",
            status: "pending_moderation",
            storage_object_path: "pending/00000000-0000-4000-8000-000000002104.jpg",
        }),
        moveObject: async (fromPath, toPath) => {
            moves.push([fromPath, toPath]);
        },
        deleteObject: async () => undefined,
        approvePhoto: async () => {
            throw new Error("rpc_failed");
        },
        rejectPhoto: async () => ({
            report_id: "00000000-0000-4000-8000-000000002104",
            status: "rejected",
            storage_object_path: "pending/00000000-0000-4000-8000-000000002104.jpg",
        }),
    });

    const response = await handler(new Request("http://localhost/functions/v1/pothole-photo-moderation", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
            report_id: "00000000-0000-4000-8000-000000002104",
            decision: "approve",
            reviewed_by: "mod-5",
        }),
    }));

    assertEquals(response.status, 502);
    assertEquals(moves, [[
        "pending/00000000-0000-4000-8000-000000002104.jpg",
        "published/00000000-0000-4000-8000-000000002104.jpg",
    ], [
        "published/00000000-0000-4000-8000-000000002104.jpg",
        "pending/00000000-0000-4000-8000-000000002104.jpg",
    ]]);
});

Deno.test("pothole photo moderation handler maps invalid states to 409", async () => {
    const handler = createPotholePhotoModerationHandler({
        authorize: () => true,
        getPhoto: async () => ({
            report_id: "00000000-0000-4000-8000-000000002103",
            status: "approved",
            storage_object_path: "published/00000000-0000-4000-8000-000000002103.jpg",
        }),
        moveObject: async () => undefined,
        deleteObject: async () => undefined,
        approvePhoto: async () => ({
            report_id: "00000000-0000-4000-8000-000000002103",
            status: "approved",
            storage_object_path: "published/00000000-0000-4000-8000-000000002103.jpg",
        }),
        rejectPhoto: async () => ({
            report_id: "00000000-0000-4000-8000-000000002103",
            status: "rejected",
            storage_object_path: "pending/00000000-0000-4000-8000-000000002103.jpg",
        }),
    });

    const response = await handler(new Request("http://localhost/functions/v1/pothole-photo-moderation", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
            report_id: "00000000-0000-4000-8000-000000002103",
            decision: "reject",
            reviewed_by: "mod-4",
        }),
    }));

    assertEquals(response.status, 409);
    assertEquals((await response.json()).error, "invalid_photo_state");
});
