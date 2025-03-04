if (typeof tinyInit !== 'object')
  tinyInit = {
    selector: "textarea",
	mode: "none",
	theme: "modern",
	plugins: "compat3x advlist code paste table link zlink zmedia autosave directionality autoresize lists",
	menubar: "edit format table tools insert",
	toolbar: [
	    "styleselect | bold italic | alignleft aligncenter alignright | bullist numlist outdent indent | ltr rtl | removeformat",
		"link unlink | zlink zmedia | code"
	],

  content_css: "/lib/js/tinymce-4.5.5/zotonic.css,/lib/css/tinymce-zotonic.css",

//    language : "en", // set in _admin_tinymce_overrides_js.tpl

	/* Adapted valid element list, added some html5 elements, removed controls, object, embed etc */
	/* See: http://www.tinymce.com/wiki.php/Configuration:valid_elements */
	valid_elements : "@[class|style|title|dir<ltr?rtl|lang|xml::lang],"
	+ "a[rel|rev|charset|hreflang|tabindex|accesskey|type|name|href|target|title],"
	+ "strong/b,em/i,strike,u,"
	+ "#p,-ol[type|compact],-ul[type|compact],-li,br,img[longdesc|usemap|"
	+ "src|border|alt=|title|hspace|vspace|width|height|align],-sub,-sup,"
	+ "-blockquote,-table[border=0|cellspacing|cellpadding|width|frame|rules|"
	+ "height|align|summary|bgcolor|background|bordercolor],-tr[rowspan|width|"
	+ "height|align|valign|bgcolor|background|bordercolor],tbody,thead,tfoot,"
	+ "#td[colspan|rowspan|width|height|align|valign|bgcolor|background|bordercolor|scope],"
	+ "#th[colspan|rowspan|width|height|align|valign|scope],caption,-div,"
	+ "-span,-code,-pre,address,-h1,-h2,-h3,-h4,-h5,-h6,hr[size|noshade],"
	+ "dd,dl,dt,cite,abbr,del[datetime|cite],ins[datetime|cite],"
	+ "map[name],area[shape|coords|href|alt|target],bdo,"
	+ "col[align|char|charoff|span|valign|width],colgroup[align|char|charoff|span|valign|width],"
	+ "dfn,kbd,legend,"
	+ "q[cite],samp,small,"
	+ "tt,var,big,"
	+ "section,header,nav,article,footer,audio,video",

	relative_urls: "",
	remove_script_host: "",
	convert_urls: "",
	apply_source_formatting: "",
	remove_linebreaks: "1",
	gecko_spellcheck: "1",

	formats : {
		bdo_rtl : {inline : 'bdo', attributes : {dir: 'rtl'}},
		bdo_ltr : {inline : 'bdo', attributes : {dir: 'ltr'}}
	},

    setup: function(editor) {
        // setup code here; override in _admin_tinymce_overrides_js.tpl
    },

	/* Cleanup pasted html code */
	paste_auto_cleanup_on_paste : true,
	paste_convert_middot_lists: true,
	paste_remove_spans: true,
	paste_remove_styles: true,
	paste_remove_styles_if_webkit: true,
	paste_strip_class_attributes: true,

	/* below is a workaround for problem where tinyMCE setEntities skips the ones below and the doesn't initialize the entityLookup array
	 * which results in an error in the _encode function.
	 */
	entity_encoding: "raw",
	entities: "38,amp,60,lt,62,gt",

	accessibility_focus: "1",
	tab_focus: ":prev,:next",
	wpeditimage_disable_captions: "",
	table_row_limit: 100,
	table_col_limit: 10,
	autoresize_max_height: 400
};
