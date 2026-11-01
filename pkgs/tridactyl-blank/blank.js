// Tridactyl's new tab page, made to look like Firefox's own empty new tab.
// content.js (loaded first) provides the binds; this file only paints the
// page in the theme's colours and decides where keyboard focus goes.
"use strict"

const root = document.documentElement
const params = new URLSearchParams(location.search)

function cssColor(value) {
    return Array.isArray(value) ? `rgb(${value.join(", ")})` : value
}

function applyTheme(theme) {
    const colors = theme?.colors ?? {}
    for (const [prop, key] of [
        ["--ntp-background", "ntp_background"],
        ["--ntp-text", "ntp_text"],
    ]) {
        if (colors[key]) root.style.setProperty(prop, cssColor(colors[key]))
        else root.style.removeProperty(prop)
    }
}

async function followTheme() {
    const win = await browser.windows.getCurrent()
    applyTheme(await browser.theme.getCurrent(win.id))
    browser.theme.onUpdated.addListener(({ theme, windowId }) => {
        if (windowId === undefined || windowId === win.id) applyTheme(theme)
    })
}

// Firefox puts the cursor in the address bar for every tab it opens at the new
// tab URL, so keys would go there instead of to Tridactyl. With `newtabfocus`
// "page" (the default), such a tab is replaced by one opened at this page plus
// "?focus": tabs opened with an explicit URL get page focus, and the address
// bar still shows empty because Firefox ignores the query string for that.
// The first window and new windows open on "?focus" directly (home page).
async function replaceWithFocusedTab() {
    if (params.has("focus") || document.hasFocus()) return
    const nav = performance.getEntriesByType("navigation")[0]
    if (nav && nav.type !== "navigate") return

    const { userconfig } = await browser.storage.local.get("userconfig")
    if ((userconfig?.newtabfocus ?? "page") !== "page") return

    const tab = await browser.tabs.getCurrent()
    // Sidebar panels have no tab; background tabs keep their focus as is.
    if (!tab || !tab.active) return
    const win = await browser.windows.get(tab.windowId)
    if (!win.focused) return

    // One-shot token, so a reload or session restore of the new tab never
    // closes anything.
    const token = crypto.randomUUID()
    await browser.storage.session.set({ [`replace:${token}`]: tab.id })
    const fresh = await browser.tabs.create({
        url: `${location.pathname}?focus&replace=${token}`,
        windowId: tab.windowId,
        index: tab.index,
        active: true,
        pinned: tab.pinned,
        cookieStoreId: tab.cookieStoreId,
        ...(tab.openerTabId !== undefined && { openerTabId: tab.openerTabId }),
    })
    if (tab.groupId !== undefined && tab.groupId !== -1 && browser.tabs.group)
        await browser.tabs.group({ groupId: tab.groupId, tabIds: [fresh.id] })
    // The new tab closes this one (this page can't outlive its own tab).
}

// In the replacement tab: close the original and keep it out of "Reopen
// Closed Tab".
// (The query stays as is: rewriting it with history.replaceState would make
// Firefox show the URL in the address bar.)
async function closeReplacedTab() {
    const key = `replace:${params.get("replace")}`
    const { [key]: id } = await browser.storage.session.get(key)
    if (id === undefined) return
    await browser.storage.session.remove(key)

    const started = Date.now()
    try {
        await browser.tabs.remove(id)
    } catch {
        return // already gone (e.g. this is a reload)
    }
    for (let i = 0; i < 20; i++) {
        const [closed] = await browser.sessions.getRecentlyClosed({ maxResults: 1 })
        const url = closed?.tab?.url ?? ""
        if (url.startsWith(location.origin + location.pathname) && closed.lastModified >= started - 1000) {
            await browser.sessions.forgetClosedTab(closed.tab.windowId, closed.tab.sessionId)
            return
        }
        await new Promise(resolve => setTimeout(resolve, 100))
    }
}

followTheme().catch(console.error)
if (params.has("replace")) closeReplacedTab().catch(console.error)
else replaceWithFocusedTab().catch(console.error)
