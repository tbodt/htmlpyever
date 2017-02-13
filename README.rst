htmlpyever
==========

htmlpyever is a very single-minded binding to html5ever. You can:

* Feed the parser:

  .. code-block:: python

    parser.feed(b'hOI wURLD!')

* Get a callback when the parser encounters a closing script tag:

  .. code-block:: python
  
    def script_callback(script):
        # handle script
    parser = htmlpyever.Parser(script_callback)

    # or

    class MyParser(htmlpyever.Parser):
        def run_script(self, script)
            # handle script
    parser = MyParser()

* Obtain the result as an LXML ``Element`` or ``ElementTree``:

  .. code-block:: python
  
    from lxml import etree
    etree.tostring(parser.root)
    # >>> '<html><head/><body>hOI! wURLD!</body></html>'
    etree.tostring(parser.root)
    # >>> '<html><head/><body>hOI! wURLD!</body></html>'
    # not sure why the doctype doesn't show up in the serialized ElementTree
    
 That's it.
