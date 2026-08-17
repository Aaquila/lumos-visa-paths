/// Non-web target: there is no browser to hand a download to.
///
/// Returns false rather than throwing, so the settings screen can say "not
/// available here" instead of crashing on a platform that will never run this.
bool downloadIcs(String content, String filename) => false;
