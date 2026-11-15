# Turning on the community gallery

The gallery (accounts and shared icons) runs on **Supabase**, a free database service. The site keeps the gallery hidden until it's connected. This takes about 10 minutes.

## 1. Create a Supabase project

1. Go to <https://supabase.com> and sign up (the free plan is fine).
2. Click **New project**.
   - **Name:** `monke-icon-maker`
   - **Database password:** use the **Generate a password** button. You won't need it for the site; save it somewhere safe anyway.
   - **Region:** pick the one closest to most of your viewers.
3. Wait a minute or two while it sets up.

## 2. Create the tables and rules

1. In the left sidebar, open **SQL Editor**, then click **New query**.
2. Open [`supabase/setup.sql`](supabase/setup.sql) in this repo, copy **all** of it, and paste it into the editor.
3. Click **Run**. You should see *Success. No rows returned*.

This creates the accounts, posts and reports tables, the rule that usernames must be unique, the report and ban tools, and a storage folder for shared icons. It's safe to run again.

## 3. Turn off email confirmation

Accounts use a username instead of an email, so Supabase must not try to send confirmation emails.

1. Go to **Authentication** → **Sign In / Providers** (on some dashboards: **Providers** → **Email**).
2. Turn **Confirm email** **off** and save.
3. Make sure **Allow new users to sign up** is **on**.
4. Optional: in the password settings, set **Minimum password length** to **8** (the site already asks for 8).

## 4. Send me the two public values

1. Go to **Project Settings** (the cog) → **API Keys** / **Data API**.
2. Copy:
   - the **Project URL** (looks like `https://abcdefgh.supabase.co`)
   - the **anon public** key (a long code starting with `eyJ`). If you see tabs, it's under **Legacy API keys**. If your project only shows a **Publishable key** (starts with `sb_publishable_`), send that instead.
3. Paste both into the chat. These two are **meant to be public**; they end up in the page anyway, and the rules from step 2 decide what people can do.

> ⚠️ **Never** share the **service_role** / **secret** key. That one can bypass every rule.

I'll add them to the site, and the gallery will appear.

## 5. Make yourself admin

Once the gallery is live:

1. Create your own account on the site.
2. Back in Supabase, open **SQL Editor** → **New query**, paste this with **your** username, and click **Run**:

   ```sql
   update public.profiles set is_admin = true where username = 'your_username';
   ```

3. Reload the site. You'll see an **Admin** tag next to your name, a **🚩 Reported** tab, and **Restore**, **Delete** and **Ban** buttons on posts.

## Good to know

- **Free projects pause** after a week with no visitors. If the gallery says it can't load, open your Supabase dashboard and click **Restore project**.
- **Forgotten passwords can't be reset**, because there's no email. You can remove an account in Supabase under **Authentication** → **Users**, and the person can sign up again.
- **Limits built in:** usernames are 3–20 letters, numbers or `_`, and unique ignoring capitals; display names are up to 30 characters; each account can share up to 20 icons a day; each icon is at most 1 MB.
- **Reports:** after 3 different people report an icon, it's hidden until you **Restore** or **Delete** it from the **🚩 Reported** tab.
- **Banning** hides all of that person's icons and stops them sharing or reporting. **Unban** undoes it.
