import json
import copy

from util.json_request import JsonResponse
from django.http import HttpResponseBadRequest
from django.contrib.auth.decorators import login_required
from django.views.decorators.http import require_http_methods
from django_future.csrf import ensure_csrf_cookie
from edxmako.shortcuts import render_to_response
from django.http import HttpResponseNotFound
from django.core.exceptions import PermissionDenied
from xmodule.modulestore.django import loc_mapper

from ..utils import get_modulestore
from .access import has_course_access
from xmodule.course_module import CourseDescriptor
from xmodule.modulestore.locator import BlockUsageLocator

__all__ = ['utility_captions_handler']


# pylint: disable=unused-argument
@require_http_methods(("GET", "POST", "PUT"))
@login_required
@ensure_csrf_cookie
def utility_captions_handler(request, tag=None, package_id=None, branch=None, version_guid=None, block=None, utilities_index=None):
    """
    The restful handler for utilities.

    GET
        html: return html page for all checklists
        json: return json representing all checklists. checklist_index is not supported for GET at this time.
    POST or PUT
        json: updates the checked state for items within a particular checklist. checklist_index is required.
    """
    location = BlockUsageLocator(package_id=package_id, branch=branch, version_guid=version_guid, block_id=block)
    if not has_course_access(request.user, location):
        raise PermissionDenied()

    old_location = loc_mapper().translate_locator_to_location(location)

    modulestore = get_modulestore(old_location)
    course_module = modulestore.get_item(old_location)

    json_request = 'application/json' in request.META.get('HTTP_ACCEPT', 'application/json')
    if request.method == 'GET':
        # If course was created before checklists were introduced, copy them over
        # from the template.
        if not course_module.utilities:
            course_module.utilities = CourseDescriptor.utilities.default
            modulestore.update_item(course_module, request.user.id)

        expanded_utilities = expand_all_action_urls(course_module)
        if json_request:
            return JsonResponse(expanded_utilities)
        else:
            handler_url = location.url_reverse('utilities/', '')
            return render_to_response('utilities.html',
                                      {
                                          'handler_url': handler_url,
                                          # context_course is used by analytics
                                          'context_course': course_module,
                                          'utilities': expanded_utilities
                                      })
    elif json_request:
        # Can now assume POST or PUT because GET handled above.
        if utilities_index is not None and 0 <= int(utilities_index) < len(course_module.checklists):
            index = int(utilities_index)
            persisted_utility = course_module.utilities[index]
            modified_utility = json.loads(request.body)
            # Only thing the user can modify is the "checked" state.
            # We don't want to persist what comes back from the client because it will
            # include the expanded action URLs (which are non-portable).
            for item_index, item in enumerate(modified_utility.get('items')):
                persisted_utility['items'][item_index]['is_checked'] = item['is_checked']
            # seeming noop which triggers kvs to record that the metadata is
            # not default
            course_module.utilities = course_module.utilities
            course_module.save()
            modulestore.update_item(course_module, request.user.id)
            expanded_utility = expand_utility_action_url(course_module, persisted_utility)
            return JsonResponse(expanded_utility)
        else:
            return HttpResponseBadRequest(
                ("Could not save checklist state because the checklist index "
                 "was out of range or unspecified."),
                content_type="text/plain"
            )
    else:
        return HttpResponseNotFound()


def expand_all_action_urls(course_module):
    """
    Gets the checklists out of the course module and expands their action urls.

    Returns a copy of the checklists with modified urls, without modifying the persisted version
    of the checklists.
    """
    expanded_utilities = []
    for utility in course_module.utilities:
        expanded_utilities.append(expand_utility_action_url(course_module, utility))
    return expanded_utilities


def expand_utility_action_url(course_module, utility):
    """
    Expands the action URLs for a given checklist and returns the modified version.

    The method does a copy of the input checklist and does not modify the input argument.
    """
    expanded_utility= copy.deepcopy(utility)

    urlconf_map = {
        "UtilitiesVideoCaptions": "utilities-captions",
    }

    for item in expanded_utility.get('items'):
        action_url = item.get('action_url')
        if action_url in urlconf_map:
            url_prefix = urlconf_map[action_url]
            ctx_loc = course_module.location
            location = loc_mapper().translate_location(ctx_loc.course_id, ctx_loc, False, True)
            item['action_url'] = location.url_reverse(url_prefix, '')

    return expanded_utility
