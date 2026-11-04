-- Round4 意向登记模式，由 Synqa 于 2026-11-04 确认。
-- 第四团暂不正式开团：开放让成员登录、挑选贴纸并填写数量以统计意向。
-- 开团 / 截止 / 付款时间全部留空（NULL）：group_buy_order_window_guard 触发器因此
-- 一律放行订单写入（时间为空即不拦截），前端也不会显示任何硬日期，对应 round4.html
-- INTENT_MODE 下的「开团时间：暂定」。汇率临时按 7.0。
-- 商品、六团结构、运费沿用 20260717002500_round4_launch_config.sql，不改动。
UPDATE public.group_buy_rounds
SET status = 'open',
    exchange_rate = 7.0000,
    order_opens_at = NULL,
    order_deadline = NULL,
    payment_deadline = NULL,
    updated_at = now()
WHERE id = 'round4';
