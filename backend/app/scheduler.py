"""Scheduled news scraper with APScheduler.

Runs scrape jobs on weekdays (Mon–Fri) at 12 PM and 6 PM PT,
plus on app startup if configured.

Timezone and enabled/disabled status are read from environment variables:
- SCRAPER_TIMEZONE: timezone string (default: US/Pacific)
- SCRAPER_ENABLED: '1' or 'true' to enable (default: enabled)
"""

from __future__ import annotations

import asyncio
import logging
import os
from typing import Callable

from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.triggers.cron import CronTrigger
from pytz import timezone

log = logging.getLogger("lumos.scheduler")

# Read configuration from environment.
SCRAPER_ENABLED = os.getenv("SCRAPER_ENABLED", "1").lower() in ("1", "true", "yes")
SCRAPER_TIMEZONE = os.getenv("SCRAPER_TIMEZONE", "US/Pacific")

# Initialize the scheduler.
scheduler = BackgroundScheduler(timezone=SCRAPER_TIMEZONE)


def _job_wrapper(async_func: Callable) -> Callable:
    """Wrap an async function so APScheduler can call it as a job.

    APScheduler's BackgroundScheduler runs jobs in thread pool executors,
    so we need to bridge the async/sync boundary here.
    """

    def wrapper():
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        try:
            result = loop.run_until_complete(async_func())
            return result
        finally:
            loop.close()

    return wrapper


def register_scraper_job(scraper_func: Callable) -> None:
    """Register the main scraper job with APScheduler.

    Schedules two cron jobs on weekdays (Mon–Fri):
    - 12:00 PM PT
    - 6:00 PM PT

    The scraper_func should be an async callable that runs the scrape.
    It will be wrapped to work with APScheduler's thread pool.
    """
    if not SCRAPER_ENABLED:
        log.info("Scraper is disabled (SCRAPER_ENABLED=%s)", SCRAPER_ENABLED)
        return

    log.info(
        "Registering scraper jobs: weekdays at 12:00 PM and 6:00 PM %s",
        SCRAPER_TIMEZONE,
    )

    # Wrap the async function so it can run in APScheduler's thread pool.
    job_func = _job_wrapper(scraper_func)

    # Add 12 PM PT job (weekdays only: Mon–Fri, represented as 0–4).
    scheduler.add_job(
        job_func,
        CronTrigger(
            hour=12,
            minute=0,
            day_of_week="mon-fri",
            timezone=SCRAPER_TIMEZONE,
        ),
        id="scraper_12pm",
        name="Scraper 12:00 PM PT",
        replace_existing=True,
    )
    log.info("Added 12:00 PM PT weekday job")

    # Add 6 PM PT job (weekdays only).
    scheduler.add_job(
        job_func,
        CronTrigger(
            hour=18,
            minute=0,
            day_of_week="mon-fri",
            timezone=SCRAPER_TIMEZONE,
        ),
        id="scraper_6pm",
        name="Scraper 6:00 PM PT",
        replace_existing=True,
    )
    log.info("Added 6:00 PM PT weekday job")
