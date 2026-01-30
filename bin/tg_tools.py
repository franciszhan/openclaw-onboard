#!/usr/bin/env python3
"""Telegram read/search tools (Telethon) for on-request use.

Privacy: this tool is intended for fetch/search on request.
Secrets:
  - Reads TG_API_ID / TG_API_HASH from /opt/openclaw/secret/tg.env
  - Session stored at /opt/openclaw/secret/telethon.session

Usage examples:
  python3 tg_tools.py dialogs --limit 30
  python3 tg_tools.py tail --chat "@username" --limit 50
  python3 tg_tools.py search --query "foo bar" --limit 20
"""

import argparse
import asyncio
import os
from pathlib import Path

from dotenv import load_dotenv
from telethon import TelegramClient

BASE = Path("/opt/openclaw/secret")
ENV_PATH = BASE / "tg.env"
SESSION_PATH = str(BASE / "telethon")

load_dotenv(ENV_PATH)


def get_client() -> TelegramClient:
    api_id = os.environ.get("TG_API_ID")
    api_hash = os.environ.get("TG_API_HASH")
    if not api_id or not api_hash:
        raise SystemExit("Missing TG_API_ID/TG_API_HASH (check /opt/openclaw/secret/tg.env)")
    return TelegramClient(SESSION_PATH, int(api_id), api_hash)


async def cmd_login(args):
    client = get_client()
    await client.connect()
    if not await client.is_user_authorized():
        if not args.phone:
            raise SystemExit("First-time login requires --phone +<countrycode><number>")
        await client.send_code_request(args.phone)
        code = input("Enter the Telegram login code you received: ").strip()
        try:
            await client.sign_in(args.phone, code)
        except Exception as e:
            if "password" in str(e).lower():
                pwd = input("Enter your Telegram 2FA password: ")
                await client.sign_in(password=pwd)
            else:
                raise
    me = await client.get_me()
    print(f"Logged in as: {me.id} @{getattr(me, 'username', None)}")
    await client.disconnect()


async def cmd_dialogs(args):
    client = get_client()
    async with client:
        dialogs = await client.get_dialogs(limit=args.limit)
        for d in dialogs:
            ent = d.entity
            title = getattr(ent, "title", None) or getattr(ent, "username", None) or getattr(ent, "first_name", None)
            print(f"{d.id}\t{title}")


async def cmd_tail(args):
    client = get_client()
    async with client:
        entity = await client.get_entity(args.chat)
        msgs = await client.get_messages(entity, limit=args.limit)
        for m in reversed(msgs):
            text = (m.message or "").replace("\n", " ")
            # Note: this prints message text; use only when explicitly requested.
            print(f"[{m.date.isoformat()}] {text}")


async def cmd_search(args):
    client = get_client()
    async with client:
        it = client.iter_messages(None, search=args.query, limit=args.limit)
        async for m in it:
            chat = None
            try:
                c = await m.get_chat()
                chat = getattr(c, "title", None) or getattr(c, "username", None) or getattr(c, "first_name", None)
            except Exception:
                chat = str(getattr(m, "chat_id", None))
            text = (m.message or "").replace("\n", " ")
            print(f"[{m.date.isoformat()}] in {chat}: {text}")


def main():
    p = argparse.ArgumentParser()
    sp = p.add_subparsers(dest="cmd", required=True)

    p_login = sp.add_parser("login")
    p_login.add_argument("--phone", help="Phone in E.164, e.g. +15551234567")
    p_login.set_defaults(fn=cmd_login)

    p_dialogs = sp.add_parser("dialogs")
    p_dialogs.add_argument("--limit", type=int, default=30)
    p_dialogs.set_defaults(fn=cmd_dialogs)

    p_tail = sp.add_parser("tail")
    p_tail.add_argument("--chat", required=True)
    p_tail.add_argument("--limit", type=int, default=50)
    p_tail.set_defaults(fn=cmd_tail)

    p_search = sp.add_parser("search")
    p_search.add_argument("--query", required=True)
    p_search.add_argument("--limit", type=int, default=20)
    p_search.set_defaults(fn=cmd_search)

    args = p.parse_args()
    asyncio.run(args.fn(args))


if __name__ == "__main__":
    main()
