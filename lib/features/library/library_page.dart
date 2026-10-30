import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../data/models/object_library_models.dart';
import '../../data/storage/attachment_image.dart';
import '../../data/models/library_models.dart' show Asset, AssetKind, extractUrl;
import '../../data/repositories/library_repository.dart';
import '../../widgets/common.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key,required this.state,this.initialObjectId});
  final AppState state;
  final String? initialObjectId;
  @override State<LibraryPage> createState()=>_LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final _query=TextEditingController();
  String? _space;
  String _sort='newest';
  AppState get s=>widget.state;
  LibraryRepository get repo=>s.library;

  @override void initState(){super.initState();WidgetsBinding.instance.addPostFrameCallback((_){
    final item=widget.initialObjectId==null?null:s.workspace.libraryObjects[widget.initialObjectId!];
    if(item!=null&&mounted)_open(item);
  });}

  @override void dispose(){_query.dispose();super.dispose();}

  Future<void> _saveUrl() async {
    final raw=await promptText(context,title:'Save a website',hint:'https://example.com',action:'Save');
    if(raw==null)return;
    final url=extractUrl(raw);
    if(url==null){s.showToast('Enter a valid http or https address.');return;}
    final result=await repo.save(type:LibraryObjectType.website,sourceUrl:url,title:Uri.parse(url).host,spaceId:_space);
    if(mounted) setState((){});
    s.showToast(result.sourceUrl==null?'Saved.':'Saved locally. Open the source to view it; page extraction is not enabled.');
  }

  Future<void> _newNote() async {
    final title=await promptText(context,title:'New library note',hint:'Title',action:'Continue');
    if(!mounted || title==null)return;
    final body=await promptText(context,title:'Note content',hint:'Write a note…',action:'Save');
    if(body==null)return;
    await repo.save(type:LibraryObjectType.note,title:title,content:body,spaceId:_space);
    if(mounted)setState((){});
  }

  Future<void> _importFiles({required bool images}) async {
    final assets=images?await s.capture.pickImages():await s.capture.pickDocuments();
    for(final asset in assets){
      final info=asset.file==null?null:await s.workspace.attachments.contentInfo(asset.file!);
      if(info!=null){s.workspace.assets.put(asset.copyWith(fileSha256:info.$1,fileSize:info.$2));await s.workspace.assets.flush();}
      await repo.save(type:asset.kind==AssetKind.image?LibraryObjectType.image:LibraryObjectType.document,
        title:asset.label,attachmentIds:[asset.id],metadata:{'legacyAssetId':asset.id},spaceId:_space);
    }
    if(mounted)setState((){});
  }

  Future<void> _newSpace({required bool smart}) async {
    final name=await promptText(context,title:smart?'New Smart Space':'New Space',hint:'Name',action:'Continue');
    if(!mounted || name==null)return;
    final query=smart?await promptText(context,title:'Smart Space search',hint:'type:image object:chair',action:'Save')??'':'';
    final parsed=LibraryQuery.parse(query);
    if(smart&&parsed.error!=null){s.showToast(parsed.error!);return;}
    final space=await repo.createSpace(name,kind:smart?LibrarySpaceKind.smart:LibrarySpaceKind.regular,query:query);
    if(mounted)setState(()=>_space=space.id);
  }

  @override Widget build(BuildContext context){
    return ListenableBuilder(listenable:Listenable.merge([s.workspace.libraryObjects,s.workspace.librarySpaces,
      s.workspace.libraryIndex,s.workspace.libraryRelations,s.workspace.libraryJobs]),builder:(context,_) {
      final result=repo.search(_query.text); final visible=(_space==null?result.items:repo.inSpace(_space!)).toList()
        ..sort((a,b)=>switch(_sort){'oldest'=>a.createdAt.compareTo(b.createdAt),'title'=>a.title.toLowerCase().compareTo(b.title.toLowerCase()),_=> (b.lastSavedAt??b.createdAt).compareTo(a.lastSavedAt??a.createdAt)});
      final spaces=s.workspace.librarySpaces.all.toList()..sort((a,b)=>a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return ColoredBox(color:AppColors.background,child:Column(children:[
        Padding(padding:const EdgeInsets.fromLTRB(24,20,24,12),child:Row(children:[
          Expanded(child:Text('Library',style:TextStyle(color:AppColors.text,fontSize:24,fontWeight:FontWeight.w600))),
          PopupMenuButton<String>(tooltip:'Add to library',onSelected:(v){switch(v){case 'url':_saveUrl();case 'note':_newNote();case 'image':_importFiles(images:true);case 'document':_importFiles(images:false);}},
            itemBuilder:(_)=>const [PopupMenuItem(value:'url',child:Text('Save website')),PopupMenuItem(value:'note',child:Text('New note')),
              PopupMenuItem(value:'image',child:Text('Import images')),PopupMenuItem(value:'document',child:Text('Import documents'))],
            child:ActionChip(avatar:const Icon(Icons.add,size:18),label:const Text('Add item'))),
        ])),
        Padding(padding:const EdgeInsets.symmetric(horizontal:24),child:TextField(controller:_query, onChanged:(_)=>setState((){}),
          style:TextStyle(color:AppColors.text),decoration:InputDecoration(prefixIcon:const Icon(Icons.search),hintText:'Search your library · type:image object:chair tag:…',
            filled:true,fillColor:AppColors.card,border:OutlineInputBorder(borderRadius:BorderRadius.circular(12),borderSide:BorderSide(color:AppColors.border)),
            enabledBorder:OutlineInputBorder(borderRadius:BorderRadius.circular(12),borderSide:BorderSide(color:AppColors.border))))),
        SizedBox(height:58,child:ListView(scrollDirection:Axis.horizontal,padding:const EdgeInsets.symmetric(horizontal:20,vertical:8),children:[
          _spaceChip('All items',null),for(final sp in spaces)_spaceButton(sp),
          Padding(padding:const EdgeInsets.symmetric(horizontal:4),child:PopupMenuButton<bool>(onSelected:(smart)=>_newSpace(smart:smart),
            itemBuilder:(_)=>const [PopupMenuItem(value:false,child:Text('Regular Space')),PopupMenuItem(value:true,child:Text('Smart Space'))],
            child:ActionChip(avatar:const Icon(Icons.add,size:16),label:const Text('New Space')))),
          PopupMenuButton<String>(tooltip:'Sort items',onSelected:(value)=>setState(()=>_sort=value),itemBuilder:(_)=>const [
            PopupMenuItem(value:'newest',child:Text('Recently saved')),PopupMenuItem(value:'oldest',child:Text('Oldest first')),PopupMenuItem(value:'title',child:Text('Title'))],
            child:const Padding(padding:EdgeInsets.all(8),child:Icon(Icons.sort))),
        ])),
        if(result.error!=null) Padding(padding:const EdgeInsets.all(12),child:Text(result.error!,style:TextStyle(color:AppColors.danger))),
        if(_space==null && _query.text.isNotEmpty && visible.isEmpty && result.error==null) Padding(padding:const EdgeInsets.all(16),child:Text('No matching items. Semantic search and visual recognition are not configured.',style:TextStyle(color:AppColors.textMuted))),
        Expanded(child:visible.isEmpty?Center(child:Text('Your library is ready for its first item.',style:TextStyle(color:AppColors.textMuted))):
          LayoutBuilder(builder:(context,c){final cols=(c.maxWidth/240).floor().clamp(1,6);
            return GridView.builder(padding:const EdgeInsets.all(20),gridDelegate:SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount:cols,crossAxisSpacing:14,mainAxisSpacing:14,childAspectRatio:.88),
              itemCount:visible.length,itemBuilder:(context,i)=>_ObjectCard(state:s,object:visible[i],onTap:()=>_open(visible[i])));
          })),
      ]));
    });
  }

  Widget _spaceChip(String label,String? id)=>Padding(padding:const EdgeInsets.symmetric(horizontal:4),child:ChoiceChip(label:Text(label),selected:_space==id,onSelected:(_)=>setState(()=>_space=id)));

  Widget _spaceButton(LibrarySpace space)=>Padding(padding:const EdgeInsets.symmetric(horizontal:4),child:PopupMenuButton<String>(
    onSelected:(action){if(action=='edit')_editSpace(space);if(action=='delete')_deleteSpace(space);},
    itemBuilder:(_)=>[if(space.kind==LibrarySpaceKind.smart)const PopupMenuItem(value:'edit',child:Text('Edit search conditions')),
      if(space.kind==LibrarySpaceKind.regular)const PopupMenuItem(value:'edit',child:Text('Rename Space')),
      const PopupMenuItem(value:'delete',child:Text('Delete Space'))],
    child:ChoiceChip(label:Text('${space.kind==LibrarySpaceKind.smart?'✦':'◈'} ${space.name}'),selected:_space==space.id,onSelected:(_)=>setState(()=>_space=space.id))));

  Future<void> _editSpace(LibrarySpace space) async {
    if(space.kind==LibrarySpaceKind.smart){
      final query=await promptText(context,title:'Edit Smart Space conditions',initial:space.query,hint:'type:image object:chair',action:'Save');
      if(query==null)return;final parsed=LibraryQuery.parse(query);if(parsed.error!=null){s.showToast(parsed.error!);return;}
      s.workspace.librarySpaces.put(space.copyWith(query:query));await s.workspace.librarySpaces.flush();
    }else{
      final name=await promptText(context,title:'Rename Space',initial:space.name,action:'Save');
      if(name==null||name.trim().isEmpty)return;s.workspace.librarySpaces.put(space.copyWith(name:name.trim()));await s.workspace.librarySpaces.flush();
    }
  }

  Future<void> _deleteSpace(LibrarySpace space) async {
    final ok=await confirm(context,title:'Delete "${space.name}"?',message:'The objects themselves will remain in your library.',action:'Delete');
    if(!ok)return;
    for(final relation in s.workspace.libraryRelations.all.where((r)=>r.kind=='space'&&r.targetId==space.id).toList()) {
      s.workspace.libraryRelations.remove(relation.id);
    }
    s.workspace.librarySpaces.remove(space.id);await s.workspace.libraryRelations.flush();await s.workspace.librarySpaces.flush();if(_space==space.id)setState(()=>_space=null);
  }

  Future<void> _open(LibraryObject object) async {
    final controller=TextEditingController(text:object.content??'');
    final titleController=TextEditingController(text:object.title);
    final noteController=TextEditingController(text:s.workspace.libraryRelations.all.where((r)=>r.objectId==object.id&&r.kind=='note').map((r)=>r.value['text']).whereType<String>().join('\n'));
    final tagController=TextEditingController();
    final attachedAsset=object.attachmentIds.map((id)=>s.workspace.assets[id]).whereType<Asset>().firstOrNull;
    await showDialog<void>(context:context,builder:(ctx)=>AlertDialog(backgroundColor:AppColors.card,title:Text(object.title.isEmpty?'Untitled':object.title),
      content: SizedBox(width:620,child:SingleChildScrollView(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text('${object.type.name.toUpperCase()}  ·  ${object.mainEntity?.type.name??'No main entity'}',style:TextStyle(color:AppColors.textMuted)),
        TextField(controller:titleController,decoration:const InputDecoration(labelText:'Title')),
        if(object.description!=null)Text(object.description!,style:TextStyle(color:AppColors.textMuted)),
        if(object.sourceUrl!=null)SelectableText(object.sourceUrl!,style:TextStyle(color:AppColors.accent)),
        if(attachedAsset?.kind==AssetKind.document&&attachedAsset?.file!=null)TextButton.icon(onPressed:(){final f=s.workspace.documentFile(attachedAsset!);if(f!=null)s.openDocument(f.path);},icon:const Icon(Icons.open_in_new),label:const Text('Open document')),
        if(object.sourceUrl!=null)TextButton.icon(onPressed:()=>s.openUrl(object.sourceUrl!),icon:const Icon(Icons.open_in_new),label:const Text('Open source')),
        const SizedBox(height:12),if(object.summary!=null)Text(object.summary!,style:TextStyle(color:AppColors.text)),
        if(object.type==LibraryObjectType.note)TextField(controller:controller,maxLines:8,decoration:const InputDecoration(labelText:'Saved content'))
        else if(object.content?.isNotEmpty==true)SelectableText(object.content!,style:TextStyle(color:AppColors.text,height:1.55)),
        TextField(controller:noteController,maxLines:3,decoration:const InputDecoration(labelText:'Your notes')),
        Row(children:[Expanded(child:TextField(controller:tagController,decoration:const InputDecoration(labelText:'Add a manual tag'))),
          IconButton(icon:const Icon(Icons.add),onPressed:() async {final tag=tagController.text.trim();if(tag.isEmpty)return;
            await repo.setManualTag(object.id,tag);tagController.clear();setState((){});})]),
        Wrap(spacing:6,children:[for(final r in s.workspace.libraryRelations.all.where((r)=>r.objectId==object.id&&r.kind=='tag'))Chip(label:Text(r.targetId,style:TextStyle(color:AppColors.text)),onDeleted:() async {await repo.removeRelation(r.id);})]),
        TextButton.icon(onPressed:()=>_manageSpaces(object),icon:const Icon(Icons.folder_open),label:const Text('Manage Regular Spaces')),
        const SizedBox(height:8),Text('Processing',style:TextStyle(color:AppColors.text,fontWeight:FontWeight.w600)),
        for(final job in s.workspace.libraryJobs.all.where((j)=>j.objectId==object.id && j.stage!=LibraryJobStage.extract)) Row(children:[Expanded(child:Text('${job.stage.name}: ${job.status.name}${job.error==null?'':' · ${job.error}'}',style:TextStyle(color:AppColors.textMuted,fontSize:12))),
          if(job.status==LibraryJobStatus.failed||job.status==LibraryJobStatus.retry)TextButton(onPressed:()=>repo.retryJob(job.id),child:const Text('Retry'))]),
      ]))),actions:[TextButton(onPressed:() async {
        final ok=await confirm(ctx,title:'Remove this item from the library?',message:'The saved object will be hidden. Its attached files remain untouched.',action:'Remove');
        if(ok){await repo.delete(object.id);if(ctx.mounted)Navigator.pop(ctx);setState((){});}
      },child:const Text('Remove')),TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Close')),FilledButton(onPressed:() async {
        final latest=s.workspace.libraryObjects[object.id]??object;
        await repo.update(latest.copyWith(title:titleController.text,content:controller.text));
        await repo.setUserNote(object.id,noteController.text);
        if(ctx.mounted)Navigator.pop(ctx);setState((){});
      },child:const Text('Save'))]));
    controller.dispose();titleController.dispose();noteController.dispose();tagController.dispose();
  }

  Future<void> _manageSpaces(LibraryObject object) async {
    await showDialog<void>(context:context,builder:(ctx)=>StatefulBuilder(builder:(ctx,setDialogState){
      final spaces=s.workspace.librarySpaces.all.where((sp)=>sp.kind==LibrarySpaceKind.regular).toList();
      final memberships=s.workspace.libraryRelations.all.where((r)=>r.objectId==object.id&&r.kind=='space').map((r)=>r.targetId).toSet();
      return AlertDialog(backgroundColor:AppColors.card,title:const Text('Regular Spaces'),content:SizedBox(width:360,child:Column(mainAxisSize:MainAxisSize.min,children:[
        for(final space in spaces)CheckboxListTile(value:memberships.contains(space.id),title:Text(space.name),onChanged:(checked){
          if(checked==true) {
            repo.addToRegularSpace(space.id,object.id);
          } else {
            repo.removeFromRegularSpace(space.id,object.id);
          }
          setDialogState((){});setState((){});
        }),
        if(spaces.isEmpty)const Text('Create a Regular Space from the library view.'),
      ])),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Done'))]);
    }));
  }
}

class _ObjectCard extends StatelessWidget {
  const _ObjectCard({required this.state,required this.object,required this.onTap});
  final AppState state;final LibraryObject object;final VoidCallback onTap;
  @override Widget build(BuildContext context){
    final assetId=object.attachmentIds.where((id)=>id.isNotEmpty).firstOrNull;
    final asset=assetId==null?null:state.workspace.assets[assetId];
    final imageName=object.thumbnailId??asset?.previewFile??asset?.file;
    return Card(color:AppColors.card,clipBehavior:Clip.antiAlias,child:InkWell(onTap:onTap,child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Expanded(child:ColoredBox(color:AppColors.cardRaised,child:Center(child:imageName!=null?Image(image:AttachmentImageProvider(state.workspace.attachments,imageName),fit:BoxFit.cover,width:double.infinity):
        Icon(switch(object.type){LibraryObjectType.image=>Icons.image_outlined,LibraryObjectType.article=>Icons.article_outlined,LibraryObjectType.website=>Icons.language,LibraryObjectType.document=>Icons.picture_as_pdf_outlined,LibraryObjectType.note=>Icons.notes,LibraryObjectType.video=>Icons.movie_outlined,_=>Icons.bookmark_border},size:44,color:AppColors.textMuted)))),
      Padding(padding:const EdgeInsets.all(12),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text(object.title.isEmpty?'Untitled':object.title,maxLines:2,overflow:TextOverflow.ellipsis,style:TextStyle(color:AppColors.text,fontWeight:FontWeight.w600)),
        const SizedBox(height:4),Text(object.mainEntity?.name??object.sourceUrl??object.type.name,maxLines:1,overflow:TextOverflow.ellipsis,style:TextStyle(color:AppColors.textMuted,fontSize:12)),
      ])),
    ])));
  }
}
