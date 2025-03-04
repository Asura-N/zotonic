{% include "_js_include_jquery.tpl" %}
{% lib
    "js/modules/jstz.min.js"
    "cotonic/cotonic.js"
	"bootstrap/js/bootstrap.min.js"
	"js/apps/zotonic-wired.js"
	"js/apps/z.widgetmanager.js"

    "js/modules/z.live.js"
    "js/modules/z.notice.js"
    "js/modules/z.tooltip.js"
    "js/modules/z.dialog.js"
	"js/modules/livevalidation-1.3.js"
	"js/modules/jquery.loadmask.js"
%}

{% script %}

<script type="text/javascript">
	$(function()
	{
	    $.widgetManager();
	});
</script>

{% worker name="auth" src="js/zotonic.auth.worker.js" args=%{  auth: m.authentication.status  } %}
