import { db, type DB } from "../db.ts";
import type { FeedbackInsertResult, FeedbackPayload } from "./handler.ts";

export function createPgInsertFeedback(sqlOverride?: DB) {
    return async (params: {
        payload: FeedbackPayload;
        clientIp: string;
        userAgent: string | null;
        requestId: string;
    }): Promise<FeedbackInsertResult> => {
        const sql = sqlOverride ?? db();
        const rows = (await sql`
            INSERT INTO feedback_submissions (
                source, category, message, reply_email, contact_consent,
                app_version, platform, locale, route,
                user_agent, client_ip, request_id
            ) VALUES (
                ${params.payload.source},
                ${params.payload.category},
                ${params.payload.message},
                ${params.payload.reply_email},
                ${params.payload.contact_consent},
                ${params.payload.app_version},
                ${params.payload.platform},
                ${params.payload.locale},
                ${params.payload.route},
                ${params.userAgent},
                ${params.clientIp},
                ${params.requestId}
            )
            RETURNING id
        `) as Array<{ id: string }>;

        if (rows.length === 0) {
            throw new Error("feedback insert returned no rows");
        }
        return { id: String(rows[0].id) };
    };
}
