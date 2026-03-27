# FieldPulse SIP Phone Readiness Guide

### Your step-by-step guide to getting ready for FieldPulse Engage phone service

---

## Welcome!

You're about to switch to FieldPulse Engage for your business phone service. This guide will help you:

- Run a quick network check on your computer
- Understand what the results mean
- Know who to call if something needs to be fixed
- Get your phones ready for setup

**No technical experience needed** — just follow the steps below.

---

## Table of Contents

1. [Running the Network Check](#1-running-the-network-check)
2. [Understanding Your Results](#2-understanding-your-results)
3. [Common Issues & Who to Call](#3-common-issues--who-to-call)
4. [Preparing Your Phones](#4-preparing-your-phones)
5. [Frequently Asked Questions](#5-frequently-asked-questions)
6. [Getting Help](#6-getting-help)

---

## 1. Running the Network Check

### Step 1: Open the Tool

1. Find the file called **FieldPulse-SIP-Readiness.exe**
2. Double-click to open it

> **See a security warning?** This is normal for new software. Click **"More info"** then **"Run anyway"** to continue.

### Step 2: Enter Your Information

1. Type your **company name** in the box at the top
2. Click the **"Run Checks"** button
3. Wait about 30 seconds for the tests to complete

### Step 3: Review & Submit

1. Look at the results (green = good, yellow = warning, red = needs attention)
2. Click **"Send to FieldPulse"**
3. Fill in the form with your phone details
4. Click **Submit**

That's it! The FieldPulse team will review your results and contact you.

---

## 2. Understanding Your Results

### What the Colors Mean

| Color | Symbol | What It Means |
|-------|--------|---------------|
| **Green** | ✓ PASS | Everything looks good! |
| **Yellow** | ! WARN | Might need attention, but not critical |
| **Red** | ✗ FAIL | Needs to be fixed before phones will work |

### Common Results Explained

| Result | What It Means | What To Do |
|--------|---------------|------------|
| **Wired adapter active** | Your computer is connected with a cable | Great! This is ideal for phone calls |
| **Wi-Fi only detected** | No wired connection found | Phones should use wired internet, not Wi-Fi |
| **Latency good** | Your internet is fast enough | No action needed |
| **Latency too high** | Internet may be slow or congested | See "Slow Internet" below |
| **Connection blocked** | Firewall is blocking phone traffic | See "Firewall Issues" below |

---

## 3. Common Issues & Who to Call

### Issue: "Connection to FieldPulse IPs blocked"

**What this means:** Your internet equipment or company firewall is blocking the connections needed for phone calls.

**Who to contact:**

| Your Situation | Who to Call | What to Ask For |
|----------------|-------------|-----------------|
| Home internet (Comcast, AT&T, Spectrum, etc.) | Your internet provider's support line | "I need to allow outbound connections on ports 5060 and 5061 for my VoIP phone service" |
| Office with IT department | Your IT team or help desk | "We need firewall rules opened for SIP phone service — I have a list of IPs and ports" |
| Small office, no IT | The company that set up your internet/router | "I need help configuring my router for VoIP phones" |

---

### Issue: "Latency too high" or "Jitter too high"

**What this means:** Your internet connection is too slow or unstable for clear phone calls.

**Who to contact:**

| Your Situation | Who to Call | What to Ask For |
|----------------|-------------|-----------------|
| Slow internet overall | Your internet provider | "I need to upgrade my internet speed" or "I'm experiencing slow speeds, can you check my connection?" |
| Internet is usually fast | Your internet provider | "I'm having intermittent connection issues that affect my VoIP calls" |
| Using Wi-Fi | Nobody — fix it yourself! | Connect your computer/phones with an ethernet cable instead |

**Tip:** If you're not sure who your internet provider is, look at your monthly internet bill or check your router for a logo.

---

### Issue: "SIP ALG detected" or Router Warning

**What this means:** A setting on your router may interfere with phone calls.

**Who to contact:**

| Your Situation | Who to Call | What to Ask For |
|----------------|-------------|-----------------|
| You own your router | Router manufacturer support, or search Google | "How do I disable SIP ALG on my [router brand] router?" |
| Router provided by internet company | Your internet provider | "I need to disable SIP ALG for my VoIP service" |
| Office router managed by IT | Your IT team | "We need to disable SIP ALG — it's interfering with our new phone system" |

---

## 4. Preparing Your Phones

Before FieldPulse can set up your phones, please complete these steps:

### Checklist

- [ ] **Contact your old phone provider** — Tell them you're switching and ask them to "release" your phones or phone numbers
- [ ] **Factory reset your phones** — This clears old settings (see instructions below)
- [ ] **Update phone firmware** — Make sure phones have the latest software
- [ ] **Gather phone information** — Model numbers, MAC addresses (label on back of phone)

### How to Factory Reset Common Phone Brands

**Yealink Phones:**
1. Press and hold **OK** button while plugging in the phone
2. Wait for "Factory Reset" prompt
3. Press **OK** to confirm

**Polycom Phones:**
1. Go to **Settings** → **Advanced** (password: 456)
2. Select **Admin Settings** → **Reset to Defaults**
3. Confirm the reset

**Cisco Phones:**
1. Unplug the phone
2. Hold the **#** button while plugging back in
3. Keep holding until lights flash

**Other brands:** Search Google for "[your phone brand] factory reset" or ask FieldPulse for help.

---

## 5. Frequently Asked Questions

### About the Network Check

**Q: Is this tool safe to run?**
> Yes! It only tests your internet connection — it doesn't install anything or change any settings on your computer.

**Q: Why does Windows show a security warning?**
> Windows shows this warning for any new software it hasn't seen before. It's safe to click "More info" and "Run anyway."

**Q: Do I need to be an administrator to run this?**
> No, regular user permissions are fine.

**Q: Can I run this on a Mac?**
> Currently, the tool only works on Windows. If you only have Macs, contact FieldPulse and they can help test your network another way.

---

### About My Internet

**Q: How do I find out who my internet provider is?**
> - Check your monthly internet bill
> - Look at your router/modem for a logo (Comcast, AT&T, Spectrum, etc.)
> - Search your email for "internet bill" or "broadband"

**Q: Do I own my router or is it rented?**
> - **Rented/Leased:** If you pay a monthly "equipment fee" on your internet bill, you're renting it
> - **Owned:** If you bought it yourself from a store or online, you own it
> - **Not sure:** Call your internet provider and ask

**Q: What internet speed do I need for phone calls?**
> - Minimum: 1 Mbps upload per phone line
> - Recommended: 5+ Mbps upload for multiple phones
> - You can test your speed at [speedtest.net](https://www.speedtest.net)

---

### About My Phones

**Q: Can I keep my current phone numbers?**
> Usually yes! This is called "porting." FieldPulse will help you transfer your numbers from your old provider.

**Q: Do I need to buy new phones?**
> Not necessarily. Many existing SIP phones work with FieldPulse. The readiness check will help identify your current phones.

**Q: What if I don't know my phone's model or MAC address?**
> - **Model:** Usually printed on the front or bottom of the phone
> - **MAC address:** A code like "AA:BB:CC:DD:EE:FF" — look for a sticker on the bottom or back of the phone

---

### About the Setup Process

**Q: How long does setup take?**
> Typically 1-2 hours for the actual phone configuration, scheduled at a time convenient for you.

**Q: Will my phones be down during setup?**
> There may be a brief period (15-30 minutes) when phones are being switched over. FieldPulse will coordinate timing with you.

**Q: Do I need to be present for setup?**
> Someone should be available to confirm the phones are working, but you don't need technical expertise.

---

## 6. Getting Help

### Still Have Questions?

**Contact FieldPulse Support:**
- Email: support@fieldpulse.com
- Include your company name and describe your question

**What to Have Ready:**
- Your company name
- The results from the readiness check (or a screenshot)
- Your phone model(s) if known

---

### Useful Search Terms

If you need to search Google or ask an AI assistant (like ChatGPT) for help, try these phrases:

**For router/firewall issues:**
> "How do I open ports 5060 and 5061 on my [router brand] router"
> "How to disable SIP ALG on [router brand]"
> "Allow VoIP traffic through [router brand] firewall"

**For internet issues:**
> "How to improve VoIP call quality"
> "Reduce network latency for phone calls"
> "QoS settings for VoIP on [router brand]"

**For phone issues:**
> "Factory reset [phone brand] [phone model]"
> "Find MAC address on [phone brand] phone"
> "Update firmware on [phone brand] [phone model]"

---

### Quick Reference Card

| I need to... | Contact... | Say this... |
|--------------|------------|-------------|
| Open firewall ports | Internet provider or IT | "Allow ports 5060, 5061 outbound for VoIP" |
| Disable SIP ALG | Internet provider or IT | "Disable SIP ALG on my router" |
| Improve internet speed | Internet provider | "I need faster upload speed for VoIP" |
| Release my old phones | Previous phone provider | "I'm switching providers, please release my equipment" |
| Port my phone numbers | FieldPulse | "I want to keep my current phone numbers" |
| Get help with setup | FieldPulse support | support@fieldpulse.com |

---

*This guide is provided by FieldPulse to help you prepare for your new phone service. Last updated: March 2026*
