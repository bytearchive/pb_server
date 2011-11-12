/*
 * Standard Command Pattern
 * 
 * PB.CommandQueue keeps list of PB.Command , manages undo redo
 * 
 * 
 */
"use strict"

PB.CommandQueue = {

	completeQ: [],	// Already executed commands
	undoneQ: [], // Commands that have been undone
	historyLogQ: [], // log of all commands executed. Used for saving
	
	trace: function(f) {
		return;
		console.log(f + this);
	},
	// Execute command, and push it onto the queue
	execute: function(command) {
		command.redo();
		if (command.canUndo()) {
			this.completeQ.push(command);
			this.trim();
			this.send('commandQueueChanged', this);
		}
		this.trace('execute');
	},
	
	// Push a command onto the queue, if 
	push: function(command) {
		if (command.canUndo()) {
			this.completeQ.push(command);
			this.undoneQ = [];
			this.trim();
			this.send('commandQueueChanged', this);
		}
		this.trace('push');
	},
	
	trim: function() {
		while (this.completeQ.length > 20)
			this.completeQ.shift();
	},
	
	undo: function() {
		if (this.completeQ.length > 0) {
			var cmd = this.completeQ.pop();
			if (cmd.canUndo()) {
				cmd.undo();
				this.undoneQ.push(cmd);
				this.send('commandQueueChanged', this);
				this.trace('undo');
				return;
			}
		}
		PB.warn("Can't undo");
	},
	
	redo: function() {
		if (this.undoneQ.length > 0) {
			var cmd = this.undoneQ.pop();
			if (cmd.canRedo()) {
				cmd.redo();
				this.completeQ.push(cmd);
				this.send('commandQueueChanged', this);
		this.trace('redo');
				return;
			}
		}
		PB.warn("Can't redo");
	},
	refresh: function() {
		var changed = false;
		if (this.completeQ.length > 0 
			&& !this.completeQ[ this.completeQ.length-1 ].canUndo())  {
				// Last command cannot be undone any more
				this.completeQ = [];
				changed = true;
			}
		if (this.undoneQ.length > 0 
			&& !this.undoneQ[ this.undoneQ.length-1 ].canRedo()) {
				// Undone command cannot be redone any more
				this.undoneQ = [];
				changed = true;
			}
		if (changed)
			this.send('commandQueueChanged', this);
	},
	
	canRedo: function() {
		this.refresh();
		return this.undoneQ.length > 0;
	},
	
	canUndo: function() {
		this.refresh();
		return this.completeQ.length > 0;
	},
	toStringQueue: function(q) {
		var s = "";
		q.forEach(function(el) {
			s += el + "\n";
		});
		return s;
	},
	toString: function() {
		var s = "CommandQueue:\nComplete:\n" + this.toStringQueue(this.completeQ);
		s += "Undone:\n" + this.toStringQueue(this.undoneQ);
		return s;
	},
	logHistory: function(cmd, opCode) {
		this.logHistory.push([kind, cmd]);
	},
	getSerializedLogHistory: function(opCode) {
		retVal = [];
		this.logHistory.forEach(function(x) {
		});
	}
}
$.extend(PB.CommandQueue, new PB.EventBroadcaster("commandQueueChanged"));

PB.Commands = {};

// All commands should support this API
PB.Commands.prototype = {
	canUndo: function() {
		alert("implement me");
	},
	canRedo: function() {
		alert("implement me");
	},
	redo: function() {
		alert("need to implement redo");
	},
	undo: function() {
		alert("need to implement redo");
	}
}

PB.Commands.DropImage = function(page, photoBroker, bookImage) {
	PB.assertId(bookImage);
	this.bookImageId = $(bookImage).attr("id");
	this.photoBroker = photoBroker;
	this.page = page;
}

PB.Commands.DropImage.prototype = {
	canUndo: function() {
		return 'oldSrc' in this;
	},
	canRedo: function() {
		return true;
	},
	redo: function() {
		// Load in the dom
		var dom = $(this.page.getDom());
		var bookImage = dom.find("#" + this.bookImageId);
		var img = bookImage.find("img").get(0);
		// Save for redo
		this.oldSrc = img ? img.src : null;
		// Create the image
		if (img) 
			img.style.visibility = 'hidden';
		else {
			img = $('<img class="actual-image" style="visibility:hidden"/>').get(0);
			if ('generatedId' in this)	// if we have to recreate the element, recreate with same id
				img.id = this.generatedId;
			else {
				PB.generateId(img);
				this.generatedId = img.id;
			}
			bookImage.append(img);
		}
	  img.onload = function(ev) {
				PB.UI.Bookpage.imageLoaded(bookImage);
				img.style.visibility = "visible";
		};
		img.src = this.photoBroker.getImageUrl('display');
		this.page.updateIcon(bookImage);
		this.page.setDomModified();
	},
	undo: function() {
		// Load in the dom
		var dom = $(this.page.getDom());
		var bookImage = dom.find("#" + this.bookImageId);
		// Set the old image
		if (this.oldSrc != null)
			bookImage.find("img").attr("src", this.oldSrc);
		else
			bookImage.find("img").detach();
		PB.UI.Bookpage.imageLoaded(bookImage);
		this.page.updateIcon(bookImage);
		this.page.setDomModified();
		delete this.oldSrc;
	},
	toString: function() {
		return "dropImage:" + this.photoBroker.id + "=>" + this.bookImageId;
	}
}
/* 
    Page CSS manipulation within command framework

Constructors:
	SetCSS(newCss, oldCss)
	newCss is an array of selector -> style:map
	oldCss is optional, just like newCss, but contains original values
   
Usage:
   cmd = new SetCSS([$("#el"), { position: 5px}]);

	 if command is to be executed once:
	 PB.CommandQueue.execute(cmd);

	 or, if cmd needs to be executed continuously:
	 cmd.redo();
	 cmd.setProps($("#el"), {position: 10px}).redo();
	 cmd.setProps($("#el"), {position: 15px}).redo();
	 PB.CommandQueue.push(cmd);
*/ 
PB.Commands.SetCSS = function(page, newCss, oldCss) {
	// deep copy incoming styles
	newCss = newCss.slice(0);
	for (var i=0; i< newCss.length; i++) { 
		var dom = $(newCss[i].dom);	// convert dom elements to ids
		PB.assertId(dom);
		newCss[i] = {dom: "#" + dom.prop('id'), style: jQuery.extend({}, newCss[i].style)};
		newCss[i].dom = "#" + dom.prop('id');
	}
	if (oldCss) {
			oldCss = oldCss.slice(0);
			for (var i=0; i< oldCss.length; i++) {
				var dom = $(oldCss[i].dom);
				PB.assertId(dom);
				oldCss[i] = {dom: "#" + dom.prop('id'), style: jQuery.extend({}, oldCss[i].style)} ;
			}
	}
	this.newCss = newCss;
	this.oldCss = oldCss;
	this.page = page;
	this.animate = true;
}

PB.Commands.SetCSS.prototype = {
	canUndo: function() {
		return this.oldCss != null;
	},
	canRedo: function() {
		return this.newCss != null;
	},
	redo: function() {
		this.applyCss(this.newCss);
	},
	undo: function() {
		this.applyCss(this.oldCss, true);
	},
	saveCss: function() {
		if (this.oldCss)
			return;
		this.oldCss = [];
		for (var i=0; i< this.newCss.length; i++) {
			var oldStyle = {};
			var dom = this.page.find(this.newCss[i].dom);
			for (var pname in this.newCss[i].style) {
				var pval = dom.css(pname);
				if (pval === undefined)
					pval = '';
				oldStyle[pname] = pval;
			}
			this.oldCss.push({ dom: this.newProps[i].dom, style: oldStyle});
		}
	},
	applyCss: function(css) {
	 	if (css == null) return;
		var dom = $(this.page.getDom());
		this.saveCss();
		for (var i=0; i< css.length; i++) {
			var el = dom.find(css[i].dom);
			el.stop(true, true);
			if (this.animate)
				el.animate(css[i].style, 150);
			else
				el.css(css[i].style);
		}
		this.page.setDomModified();
	},
	toStringCss: function(cssSpec) {
		if (cssSpec == null)
			return "null";
		var s = "";
		cssSpec.forEach(function(el) {
			s += el.dom + " => ";
			for (prop in el.style)
				s += prop + ":" + el.style[prop] + ";";
		});
		return s;
	},
	toString: function() {
		var s = "ModifyCss\noldCss: " + this.toStringCss(this.oldCss) + "\n";
		s += "newCss: " + this.toStringCss(this.newCss);
		return s;
	}
}

PB.Commands.SetInnerHtml = function(page, dom, oldHtml, newHtml, oldWasDefault) {
	this.page = page;
	PB.assertId(dom);
	this.domId = $(dom).prop("id");
	this.oldHtml = oldHtml;
	this.newHtml = newHtml;
	this.oldWasDefault = oldWasDefault;
}

PB.Commands.SetInnerHtml.prototype = {
	canUndo: function() {
		return this.oldHtml != null;
	},
	canRedo: function() {
		return this.newHtml != null;
	},
	redo: function() {
		this.applyHtml(this.newHtml);
	},
	undo: function() {
		this.applyHtml(this.oldHtml);
	},
	applyHtml: function(html) {
		if (html == null) return;
		var dom = $(this.page.getDom());
		var el = dom.find("#" + this.domId)
		el.prop("innerHTML", html);
		if (html == this.oldHtml) {
			if (this.oldWasDefault)
				el.removeAttr("data-user_text");
		}
		else
			el.attr("data-user_text", "true");
		this.page.setDomModified();
	}
}

PB.Commands.AddPages = function(book, selectedPages, selectedTemplates, pageCount) {
	this.book = book;
	this.selectedPages = selectedPages;
	this.selectedTemplates = selectedTemplates;
	this.pageCount = pageCount;
	this.addedPages = [];
}

PB.Commands.AddPages.prototype = {
	canUndo: function() {
		return this.pageCount > 0;
	},
	canRedo: function() {
		return 'newPages' in this && this.newPages.length > 0;
	},
	getInsertionPoint: function() {
		var pages = this.book.pages;
		// Where do we insert the pages?
		var insertAfter = -1;
		if (this.selectedPages.length == 0) {	// no selection, at the end
			insertAfter = pages.length - 1;
		}
		else { // there is selection, insert after last page in selection, if possible
			insertAfter = pages.indexOf(this.selectedPages[this.selectedPages.length -1]);
		}
		if (pages[insertAfter].position != 'middle') {
			if (insertAfter <= 2) // before cover/flap/inner
				while (pages[insertAfter].position != 'middle' && insertAfter < pages.length)
					insertAfter++;
			else
				while (pages[insertAfter].position != 'middle' && pos > 0)
					insertAfter--;
		}
		if (pages[insertAfter].position != 'middle') // handle degenerate case
			insertAfter = Math.floor(pages.length / 2);
		return insertAfter;
	},
	getTemplates: function() {
		if ('templates' in this)
			return this.templates;
		this.templates = [];
		
		var book_template = this.book.template;
		for (var i=0; i<this.pageCount; i++) {
			var template = i < this.selectedTemplates.length ? this.selectedTemplates[i] 
						: this.selectedTemplates[Math.floor(Math.random() * this.selectedTemplates.length)];
			if (template == "random")
				template = book_template.getRandomPage('middle');
			this.templates.push(template);
		}
		return this.templates;
	},
	// creates pages from templates
	// for undo/redo, we want to make sure we generate exactly the same pages
	// so we keep a copy, and return clones
	makePages: function(templates) {
		if ('newPages' in this) {
			var clone = [];
			this.newPages.forEach(function(page) { clone.push(Object.create(page)); });
			return clone;
		}
		this.newPages = [];
		for (var i=0; i< this.pageCount; i++)
			this.newPages.push(templates[i].makePage());
		return this.makePages(templates);	// call this again, and it will return clones
	},
	getExtraPage: function() {
		if ('extraPage' in this)
		{
			if (this.extraPage != null)
				return Object.create(this.extraPage);
			else
				return null;
		}
		if (this.book.hasOddPages()) {
			this.extraPage =  this.book.template.getRandomPage('middle').makePage();
			var pages = this.book.pages;
			var i = pages.length -1;
			while (i > 0 && pages[i].position != 'middle')
				i--;
			if (i != 0)
				this.extraInsertionPoint = i;
			else
				this.extraInsertionPoint = Math.floor(pages.length / 2);
		}
		else
			this.extraPage = null;
		return this.getExtraPage();
	},
	getExtraInsertionPoint: function() {
		return this.extraInsertionPoint;
	},
	redo: function() {
		var insertAfter = this.getInsertionPoint();
		var templates = this.getTemplates();
		var pages = this.makePages(templates);
		var THIS = this;
		pages.forEach(function(page) {
			THIS.book.addPage(page, insertAfter++);
		});
		var extraPage = this.getExtraPage();
		if (extraPage) 
			this.book.addPage(extraPage, this.getExtraInsertionPoint());
		PB.UI.Pagetab.selectPage(pages[0]);
	},
	undo: function() {
		var extraPage = this.getExtraPage();
		if (extraPage)
			this.book.deletePage(this.getExtraInsertionPoint()).deleteOnServer();
		var insertAfter = this.getInsertionPoint();
		for (var i=0; i< this.newPages.length; i++)
			this.book.deletePage(insertAfter).deleteOnServer();
	}
}
