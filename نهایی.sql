-- =========================================================
-- TADBIR NOTIFICATIONS RPC FIX
-- برای نسخه فعلی Tadbir که از users سفارشی استفاده می‌کند
-- =========================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------------------------------------------------------
-- 1) ارسال اعلان توسط مدیر
-- ---------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tadbir_send_notification(
    p_admin_id uuid,
    p_title text,
    p_body text,
    p_target text DEFAULT 'all'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    admin_ok boolean;
    target_uuid uuid;
    new_id uuid;
BEGIN
    SELECT EXISTS(
        SELECT 1 FROM public.users
        WHERE id = p_admin_id AND role = 'admin'
    ) INTO admin_ok;

    IF NOT admin_ok THEN
        RETURN jsonb_build_object('ok',false,'message','دسترسی مدیر تأیید نشد');
    END IF;

    IF trim(coalesce(p_title,'')) = '' OR trim(coalesce(p_body,'')) = '' THEN
        RETURN jsonb_build_object('ok',false,'message','عنوان و متن اعلان الزامی است');
    END IF;

    IF coalesce(p_target,'all') <> 'all' THEN
        BEGIN
            target_uuid := p_target::uuid;
        EXCEPTION WHEN invalid_text_representation THEN
            RETURN jsonb_build_object('ok',false,'message','شناسه دانش‌آموز نامعتبر است');
        END;

        IF NOT EXISTS(
            SELECT 1 FROM public.users
            WHERE id = target_uuid AND role = 'student'
        ) THEN
            RETURN jsonb_build_object('ok',false,'message','دانش‌آموز پیدا نشد');
        END IF;
    ELSE
        target_uuid := NULL;
    END IF;

    INSERT INTO public.tadbir_notifications
    (recipient_id,title,message,body,target,created_by,is_global,created_at)
    VALUES
    (
        target_uuid,
        trim(p_title),
        trim(p_body),
        trim(p_body),
        coalesce(p_target,'all'),
        p_admin_id,
        coalesce(p_target,'all')='all',
        now()
    )
    RETURNING id INTO new_id;

    RETURN jsonb_build_object(
        'ok',true,
        'id',new_id
    );
END;
$$;


-- ---------------------------------------------------------
-- 2) لیست اعلان‌های مدیر
-- ---------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tadbir_admin_notifications(
    p_admin_id uuid
)
RETURNS SETOF public.tadbir_notifications
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT EXISTS(
        SELECT 1 FROM public.users
        WHERE id = p_admin_id AND role = 'admin'
    ) THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT *
    FROM public.tadbir_notifications
    ORDER BY created_at DESC
    LIMIT 100;
END;
$$;


-- ---------------------------------------------------------
-- 3) حذف اعلان توسط مدیر
-- ---------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tadbir_delete_notification(
    p_admin_id uuid,
    p_notification_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT EXISTS(
        SELECT 1 FROM public.users
        WHERE id = p_admin_id AND role = 'admin'
    ) THEN
        RETURN jsonb_build_object('ok',false,'message','دسترسی مدیر تأیید نشد');
    END IF;

    DELETE FROM public.tadbir_notifications
    WHERE id = p_notification_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok',false,'message','اعلان پیدا نشد');
    END IF;

    RETURN jsonb_build_object('ok',true);
END;
$$;


-- ---------------------------------------------------------
-- 4) اعلان‌های مخصوص دانش‌آموز
-- ---------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tadbir_student_notifications(
    p_user_id uuid
)
RETURNS TABLE(
    id uuid,
    recipient_id uuid,
    title text,
    message text,
    body text,
    target text,
    created_by uuid,
    is_global boolean,
    created_at timestamptz,
    interaction jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT EXISTS(
        SELECT 1 FROM public.users
        WHERE users.id = p_user_id AND users.role = 'student'
    ) THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT
        n.id,
        n.recipient_id,
        n.title,
        n.message,
        n.body,
        n.target,
        n.created_by,
        n.is_global,
        n.created_at,
        CASE
            WHEN i.id IS NULL THEN NULL
            ELSE jsonb_build_object(
                'id',i.id,
                'notification_id',i.notification_id,
                'user_id',i.user_id,
                'read_at',i.read_at,
                'reaction',i.reaction,
                'is_read',i.is_read
            )
        END AS interaction
    FROM public.tadbir_notifications n
    LEFT JOIN public.tadbir_notification_interactions i
        ON i.notification_id=n.id
       AND i.user_id=p_user_id
    WHERE
        n.target='all'
        OR n.target=p_user_id::text
        OR n.recipient_id=p_user_id
    ORDER BY n.created_at DESC
    LIMIT 50;
END;
$$;


-- ---------------------------------------------------------
-- 5) علامت‌گذاری اعلان به عنوان خوانده‌شده
-- ---------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tadbir_mark_notification_read(
    p_user_id uuid,
    p_notification_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT EXISTS(
        SELECT 1 FROM public.users
        WHERE id=p_user_id AND role='student'
    ) THEN
        RETURN jsonb_build_object('ok',false,'message','دانش‌آموز معتبر نیست');
    END IF;

    INSERT INTO public.tadbir_notification_interactions
    (notification_id,user_id,read_at,is_read,updated_at)
    VALUES
    (p_notification_id,p_user_id,now(),true,now())
    ON CONFLICT(notification_id,user_id)
    DO UPDATE SET
        read_at=COALESCE(public.tadbir_notification_interactions.read_at,now()),
        is_read=true,
        updated_at=now();

    RETURN jsonb_build_object('ok',true);
END;
$$;


-- ---------------------------------------------------------
-- 6) Like / Dislike
-- ---------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tadbir_react_notification(
    p_user_id uuid,
    p_notification_id uuid,
    p_reaction text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT EXISTS(
        SELECT 1 FROM public.users
        WHERE id=p_user_id AND role='student'
    ) THEN
        RETURN jsonb_build_object('ok',false,'message','دانش‌آموز معتبر نیست');
    END IF;

    IF p_reaction NOT IN ('like','dislike') THEN
        RETURN jsonb_build_object('ok',false,'message','واکنش نامعتبر است');
    END IF;

    INSERT INTO public.tadbir_notification_interactions
    (notification_id,user_id,reaction,read_at,is_read,updated_at)
    VALUES
    (p_notification_id,p_user_id,p_reaction,now(),true,now())
    ON CONFLICT(notification_id,user_id)
    DO UPDATE SET
        reaction=p_reaction,
        read_at=COALESCE(public.tadbir_notification_interactions.read_at,now()),
        is_read=true,
        updated_at=now();

    RETURN jsonb_build_object('ok',true);
END;
$$;


-- ---------------------------------------------------------
-- 7) مجوز اجرای RPCها برای سیستم احراز هویت فعلی Tadbir
-- ---------------------------------------------------------
GRANT EXECUTE ON FUNCTION public.tadbir_send_notification(uuid,text,text,text)
TO anon, authenticated;

GRANT EXECUTE ON FUNCTION public.tadbir_admin_notifications(uuid)
TO anon, authenticated;

GRANT EXECUTE ON FUNCTION public.tadbir_delete_notification(uuid,uuid)
TO anon, authenticated;

GRANT EXECUTE ON FUNCTION public.tadbir_student_notifications(uuid)
TO anon, authenticated;

GRANT EXECUTE ON FUNCTION public.tadbir_mark_notification_read(uuid,uuid)
TO anon, authenticated;

GRANT EXECUTE ON FUNCTION public.tadbir_react_notification(uuid,uuid,text)
TO anon, authenticated;


-- ---------------------------------------------------------
-- 8) دسترسی جدول برای RPCها و سازگاری با نسخه فعلی
-- ---------------------------------------------------------
GRANT USAGE ON SCHEMA public TO anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE
ON public.tadbir_notifications
TO anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE
ON public.tadbir_notification_interactions
TO anon, authenticated;


-- ---------------------------------------------------------
-- 9) Schema cache
-- ---------------------------------------------------------
NOTIFY pgrst, 'reload schema';
